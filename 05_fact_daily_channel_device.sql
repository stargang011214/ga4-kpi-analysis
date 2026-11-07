-- =========================================================
-- 05_fact_daily_channel_device.sql
-- 용도: Power BI 메인 팩트 테이블 (일자 × 채널 × 기기 단위 집계)
-- 데이터: bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*
--        (2020-11-01 ~ 2021-01-31)
-- 분석 단위: 세션 (user_pseudo_id + ga_session_id)
-- 확정 규칙
--   날짜: 세션 시작일 = MIN(event_date), 자정 넘는 세션 중복 방지 (Day 5)
--   채널: 세션 내 첫 medium, GA4 기본 규칙 (Day 7, Day 10에 마지막 값과 비교해 확정)
--         자기 도메인 referral → referral_self, medium 없음 → (missing)
--   참여: session_engaged 문자 칸 '1'만 인정, 정수 칸은 참여 신호 아님 (Day 10)
--   퍼널: 해당 단계 '이상' 도달 기준 (Day 9)
--         begin_checkout + add_shipping_info → checkout 한 단계로 통합
--   장바구니 수집: add_to_cart가 특정 기간 미수집 (Day 10 정정, 태깅 누락 아님)
--         그날 add_to_cart < begin_checkout이면 cart_tracked = 0 (26일)
--         퍼널 비율은 cart_tracked = 1 일자만으로 계산
-- 검증: 세션 360,129 / 참여 세션 241,932 / 구매 세션 4,848 / referral_self 56,491
-- 결과(cart_tracked = 1): 단계 이탈 70.5 / 54.5 / 34.0 / 27.0%
--       → 최대 이탈 지점은 장바구니 → 결제 시작
-- =========================================================

WITH ev AS (
  SELECT
    user_pseudo_id,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_id')   AS sid,
    event_date,
    event_timestamp,
    event_name,
    device.category                                                                       AS device,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'medium')          AS medium,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'source')          AS source,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'session_engaged') AS engaged_str
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

cart_days AS (
  -- add_to_cart 수집 이상일 판별 (day10_3c_cart_missing_days와 같은 기준)
  -- 정상이라면 장바구니 이벤트가 결제 시작 이벤트보다 많아야 함
  -- 반대인 날 = 0건(11/2~11/16, 11/21~11/24) 또는 부분 수집(11/17·19·20·25, 1/22)
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS dt,
    IF(COUNTIF(event_name = 'add_to_cart') < COUNTIF(event_name = 'begin_checkout'), 0, 1)
      AS cart_tracked
  FROM ev
  GROUP BY 1
),

s AS (
  SELECT
    user_pseudo_id,
    sid,
    PARSE_DATE('%Y%m%d', MIN(event_date)) AS session_date,
    ANY_VALUE(device)                     AS device,   -- 세션당 1개 확인됨 (Day 8)
    -- 세션 내 값이 있는 첫 medium·source
    ARRAY_AGG(IF(medium IS NULL, NULL, STRUCT(medium, source))
              IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS first_ms,
    MAX(IF(engaged_str = '1', 1, 0))      AS engaged,
    -- 세션이 도달한 가장 깊은 단계 → 아래에서 ">= 단계"로 세면 '이상 도달' 기준이 됨
    MAX(CASE event_name
          WHEN 'view_item'         THEN 1
          WHEN 'add_to_cart'       THEN 2
          WHEN 'begin_checkout'    THEN 3
          WHEN 'add_shipping_info' THEN 3   -- begin_checkout과 사실상 같은 이벤트
          WHEN 'add_payment_info'  THEN 4
          WHEN 'purchase'          THEN 5
          ELSE 0 END)                     AS max_step
  FROM ev
  GROUP BY 1, 2
)

SELECT
  s.session_date,
  CASE
    WHEN s.first_ms IS NULL THEN '(missing)'
    -- 자기 도메인 referral은 외부 유입이 아님 (교차 도메인 설정 누락 추정)
    WHEN s.first_ms.medium = 'referral'
         AND s.first_ms.source LIKE '%googlemerchandisestore.com%' THEN 'referral_self'
    ELSE s.first_ms.medium
  END                         AS channel,
  s.device,
  c.cart_tracked,             -- 세션 시작일 기준으로 붙임
  COUNT(*)                    AS sessions,
  SUM(s.engaged)              AS engaged_sessions,
  COUNTIF(s.max_step >= 1)    AS f1_view_item,
  COUNTIF(s.max_step >= 2)    AS f2_add_to_cart,
  COUNTIF(s.max_step >= 3)    AS f3_checkout,
  COUNTIF(s.max_step >= 4)    AS f4_payment_info,
  COUNTIF(s.max_step >= 5)    AS f5_purchase
FROM s
JOIN cart_days c ON c.dt = s.session_date
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3;

-- ---------------------------------------------------------
-- 검증 (위 결과를 임시 테이블 fact로 저장한 뒤 실행)
-- SELECT
--   SUM(sessions) AS sessions,                                         -- 360,129
--   SUM(engaged_sessions) AS engaged,                                  -- 241,932
--   SUM(f5_purchase) AS purchase_sessions,                             -- 4,848
--   COUNT(DISTINCT IF(cart_tracked = 0, session_date, NULL)) AS cart_missing_days,  -- 26
--   ROUND(100 - SUM(IF(cart_tracked = 1, f2_add_to_cart, 0))
--             / SUM(IF(cart_tracked = 1, f1_view_item, 0)) * 100, 1) AS drop_view_cart,      -- 70.5
--   ROUND(100 - SUM(IF(cart_tracked = 1, f3_checkout, 0))
--             / SUM(IF(cart_tracked = 1, f2_add_to_cart, 0)) * 100, 1) AS drop_cart_checkout, -- 54.5
--   ROUND(100 - SUM(IF(cart_tracked = 1, f4_payment_info, 0))
--             / SUM(IF(cart_tracked = 1, f3_checkout, 0)) * 100, 1) AS drop_checkout_pay,   -- 34.0
--   ROUND(100 - SUM(IF(cart_tracked = 1, f5_purchase, 0))
--             / SUM(IF(cart_tracked = 1, f4_payment_info, 0)) * 100, 1) AS drop_pay_purchase   -- 27.0
-- FROM fact;
-- ---------------------------------------------------------
