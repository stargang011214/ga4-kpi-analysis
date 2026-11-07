-- =========================================================
-- 02_channel_conversion.sql
-- 목적: 채널(세션 내 첫 medium)별 세션 수, 구매 세션, 전환율
-- 데이터: bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*
--        (2020-11-01 ~ 2021-01-31)
-- 세션 정의: user_pseudo_id + ga_session_id
-- 검증: 세션 합계 360,129 / 구매 세션 합계 4,848
-- 결과: organic 1.61% / (none) 0.81% / cpc 0.61%
--       referral_self 56,491세션 (referral 83,781 중 67%)
--       해석 불가 채널((missing)·<Other>·(data deleted)) 약 35%
-- 주의: 여기서 referral(약 2.97%)은 source가 <Other>인 세션을 포함한 값.
--       출처 불명 소스를 뺀 외부 referral 전환율은 약 1.2%
-- =========================================================

WITH ev AS (
  SELECT
    -- 세션 키: ga_session_id는 사용자 간 겹칠 수 있어 user_pseudo_id와 결합
    CONCAT(
      user_pseudo_id,
      CAST((SELECT value.int_value FROM UNNEST(event_params)
            WHERE key = 'ga_session_id') AS STRING)
    ) AS session_key,
    event_name,
    event_timestamp,
    -- traffic_source.medium은 사용자 "최초 유입" 기준이라 세션 분석과 맞지 않음
    -- → 이벤트마다 찍히는 event_params의 medium·source 사용
    (SELECT value.string_value FROM UNNEST(event_params)
     WHERE key = 'medium') AS medium,
    (SELECT value.string_value FROM UNNEST(event_params)
     WHERE key = 'source') AS source,
    -- 참여 플래그는 문자 칸만 사용 (Day 10 정정)
    -- Day 7 원본은 정수 칸까지 COALESCE로 합쳐 참여율이 88.9%로 과대 집계됐음.
    -- 정수 칸만 1인 세션은 GA4 참여 규칙 충족률 0.1%라 참여 신호가 아님
    -- → 04_engaged_recheck.sql 참고. 전환율 계산에는 영향 없음
    (SELECT value.string_value FROM UNNEST(event_params)
     WHERE key = 'session_engaged') AS engaged
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

s AS (
  SELECT
    session_key,
    -- 세션 내 첫 medium·source를 한 쌍으로 가져옴 (GA4 기본과 같은 첫 값 규칙)
    -- NULL은 뒤로 보내서 "값이 있는 첫 이벤트"를 고름
    -- 마지막 값 기준으로 바꾸면 organic 구매 세션 상당수가
    -- 자기 도메인 referral로 덮어써져 순위가 뒤집힘 (Day 10 비교)
    ARRAY_AGG(
      STRUCT(medium, source)
      ORDER BY IF(medium IS NULL, 1, 0), event_timestamp
      LIMIT 1
    )[SAFE_OFFSET(0)] AS first_ms,
    MAX(IF(engaged = '1', 1, 0)) AS is_engaged,
    MAX(IF(event_name = 'purchase', 1, 0)) AS is_purchase
  FROM ev
  GROUP BY session_key
),

c AS (
  SELECT
    CASE
      -- 세션 안에 medium 값이 하나도 없음 (쿼리에서 붙인 이름)
      WHEN first_ms.medium IS NULL THEN '(missing)'
      -- 출처가 자기 도메인인 referral은 실제 외부 유입이 아님
      -- (교차 도메인 이동 시 출처가 덮어써진 것으로 추정, 참조 제외 설정 누락)
      -- shop.googlemerchandisestore.com 등 하위 도메인 포함
      WHEN first_ms.medium = 'referral'
           AND first_ms.source LIKE '%googlemerchandisestore.com'
        THEN 'referral_self'
      ELSE first_ms.medium
    END AS channel,
    is_engaged,
    is_purchase
  FROM s
)

SELECT
  channel,
  COUNT(*) AS sessions,
  ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 1) AS session_share_pct,
  SUM(is_purchase) AS purchase_sessions,
  ROUND(SUM(is_purchase) / SUM(SUM(is_purchase)) OVER () * 100, 1) AS purchase_share_pct,
  ROUND(SUM(is_purchase) / COUNT(*) * 100, 2) AS cvr_pct,    -- 세션 전환율
  ROUND(SUM(is_engaged) / COUNT(*) * 100, 1) AS engaged_pct  -- 참여율 (문자 칸 기준)
FROM c
GROUP BY channel
ORDER BY sessions DESC;
