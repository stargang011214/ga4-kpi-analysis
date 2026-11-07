-- =========================================================
-- 04_engaged_recheck.sql
-- 목적: 참여율 88.9%가 일반 수준(50~70%)보다 높아 GA4 참여 정의로 직접 재계산
--       → 어떤 session_engaged 값이 맞는지 판별
-- GA4 참여 세션 정의: 10초 이상 OR 페이지뷰 2회 이상 OR 키 이벤트(purchase)
--       10초는 두 방식으로 계산
--       dur: 첫~마지막 이벤트 간격 / eng: engagement_time_msec 합
-- 데이터: bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*
--        (2020-11-01 ~ 2021-01-31)
-- 세션 정의: user_pseudo_id + ga_session_id
-- 결과: 문자+정수 칸 통합 플래그 88.9% / 문자 칸 플래그 67.2%
--       GA4 정의 재계산 66.2%(eng 기준)·68.9%(dur 기준) → 문자 칸 값과 일치
--       정수 칸만 1인 세션 78,164개는 규칙 충족률 0.1% → 참여 신호 아님
-- 결론: 공식 참여율은 문자 칸 기준 67.2%
--       Day 3에서 두 칸을 COALESCE로 합친 것이 과대 집계 원인 (스스로 정정)
-- =========================================================

WITH ev AS (
  SELECT
    user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(event_params)
     WHERE key = 'ga_session_id') AS sid,
    event_name,
    event_timestamp,
    -- session_engaged가 이벤트에 따라 문자 칸('1') 또는 정수 칸(1)에 섞여 저장됨
    -- 두 칸을 따로 뽑아 각각 비교
    (SELECT value.string_value FROM UNNEST(event_params)
     WHERE key = 'session_engaged') AS engaged_str,
    (SELECT value.int_value FROM UNNEST(event_params)
     WHERE key = 'session_engaged') AS engaged_int,
    (SELECT value.int_value FROM UNNEST(event_params)
     WHERE key = 'engagement_time_msec') AS eng_ms
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

s AS (
  SELECT
    user_pseudo_id,
    sid,
    MAX(IF(engaged_str = '1', 1, 0))                     AS flag_str,       -- 문자 칸 플래그
    MAX(IF(engaged_int = 1, 1, 0))                       AS flag_int,       -- 정수 칸 플래그
    (MAX(event_timestamp) - MIN(event_timestamp)) / 1e6  AS dur_sec,        -- 마이크로초 → 초
    COALESCE(SUM(eng_ms), 0) / 1000                      AS eng_sec,        -- 밀리초 → 초
    COUNTIF(event_name = 'page_view')                    AS pv,
    MAX(IF(event_name = 'purchase', 1, 0))               AS has_purchase
  FROM ev
  GROUP BY 1, 2
),

r AS (
  SELECT
    *,
    GREATEST(flag_str, flag_int) AS flag_any,  -- Day 3 방식 (COALESCE 통합과 동일)
    IF(dur_sec >= 10 OR pv >= 2 OR has_purchase = 1, 1, 0) AS rule_dur,
    IF(eng_sec >= 10 OR pv >= 2 OR has_purchase = 1, 1, 0) AS rule_eng
  FROM s
)

SELECT
  COUNT(*)                              AS sessions,        -- 360,129
  ROUND(AVG(flag_any) * 100, 1)         AS flag_any_rate,   -- 88.9% (기존, 과대)
  ROUND(AVG(flag_str) * 100, 1)         AS flag_str_rate,   -- 67.2% (공식)
  ROUND(AVG(rule_dur) * 100, 1)         AS rule_dur_rate,   -- 68.9%
  ROUND(AVG(rule_eng) * 100, 1)         AS rule_eng_rate,   -- 66.2%

  -- 정수 칸만 1인 세션이 실제로 참여 규칙을 만족하는지
  COUNTIF(flag_int = 1 AND flag_str = 0)                    AS int_only_sessions,   -- 78,164
  ROUND(SAFE_DIVIDE(
    COUNTIF(flag_int = 1 AND flag_str = 0 AND rule_eng = 1),
    COUNTIF(flag_int = 1 AND flag_str = 0)) * 100, 1)       AS int_only_rule_rate,  -- 0.1%

  -- 기존 통합 플래그로만 참여 처리된 세션 (규칙상 비참여)
  COUNTIF(flag_any = 1 AND pv <= 1 AND eng_sec < 10 AND has_purchase = 0) AS flag_only_sessions,
  COUNTIF(pv = 0)                                                         AS no_pageview_sessions
FROM r;

-- 실행 결과 (2026-11 재실행)
-- sessions 360,129 / flag_any 88.9 / flag_str 67.2 / rule_dur 68.9 / rule_eng 66.2
-- int_only_sessions 78,164 / int_only_rule_rate 0.1
-- flag_only_sessions 81,597 / no_pageview_sessions 26,446
