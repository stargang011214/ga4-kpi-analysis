-- =========================================================
-- 03_funnel_cumulative.sql
-- 목적: 세션 기준 구매 퍼널 5단계, "해당 단계 이상 도달" 기준
--       view_item → add_to_cart → begin_checkout(+add_shipping_info)
--       → add_payment_info → purchase
-- 데이터: bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*
--        (2020-11-01 ~ 2021-01-31, 전체 기간)
-- 세션 정의: user_pseudo_id + ga_session_id
-- 검증: 0단계 360,129 / 5단계(구매) 4,848
-- 결과(전체 기간): 단계 이탈 73.7 / 45.4 / 38.6 / 28.9%
-- 주의: 이 쿼리는 add_to_cart 미수집 26일이 섞인 전체 기간 값.
--       최종 결론의 정상 수집 기간 이탈률 70.5 / 54.5 / 34.0 / 27.0%는
--       05_fact_daily_channel_device.sql의 cart_tracked = 1 일자로 계산함
--       (Day 10 정정: 핵심 이탈 지점이 장바구니 → 결제 시작으로 바뀜)
-- =========================================================

WITH ev AS (
  SELECT
    CONCAT(
      user_pseudo_id, '-',
      CAST((SELECT value.int_value FROM UNNEST(event_params)
            WHERE key = 'ga_session_id') AS STRING)
    ) AS session_key,
    event_name
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

s AS (
  -- 세션별로 각 이벤트가 1회 이상 있었는지 0/1 플래그
  SELECT
    session_key,
    MAX(IF(event_name = 'view_item', 1, 0))         AS f1,
    MAX(IF(event_name = 'add_to_cart', 1, 0))       AS f2,
    MAX(IF(event_name = 'begin_checkout', 1, 0))    AS f3,
    MAX(IF(event_name = 'add_shipping_info', 1, 0)) AS f4,
    MAX(IF(event_name = 'add_payment_info', 1, 0))  AS f5,
    MAX(IF(event_name = 'purchase', 1, 0))          AS f6
  FROM ev
  GROUP BY session_key
),

c AS (
  -- "이상 도달" 보정: 뒤 단계 이벤트가 있으면 앞 단계도 거친 것으로 봄
  -- 결제 시작 세션의 46%(5,145)가 같은 세션에 add_to_cart가 없었고,
  -- 이전 세션에 장바구니가 있던 건 7.4%뿐 → 장바구니 단계 과소 집계
  -- 단순 이벤트 유무로 세면 장바구니 15,188 → 보정 후 20,338
  SELECT
    COUNT(*)                              AS n0,  -- 전체 세션
    SUM(GREATEST(f1, f2, f3, f4, f5, f6)) AS n1,  -- 조회 이상
    SUM(GREATEST(f2, f3, f4, f5, f6))     AS n2,  -- 장바구니 이상
    -- begin_checkout과 add_shipping_info는 11,106 vs 11,105로
    -- 사실상 같은 이벤트라 한 단계로 합침 (f4를 n3에만 포함)
    SUM(GREATEST(f3, f4, f5, f6))         AS n3,  -- 결제 시작 이상
    SUM(GREATEST(f5, f6))                 AS n4,  -- 결제정보 이상
    SUM(f6)                               AS n5   -- 구매
  FROM s
)

-- 가로 한 행을 단계별 세로 행으로 펼쳐서 직전 단계와 비교
SELECT
  step_no,
  step,
  reached,
  ROUND(SAFE_DIVIDE(reached, LAG(reached) OVER (ORDER BY step_no)) * 100, 2)       AS step_conv_pct,   -- 직전 단계 대비 진행률
  ROUND(100 - SAFE_DIVIDE(reached, LAG(reached) OVER (ORDER BY step_no)) * 100, 2) AS step_drop_pct,   -- 직전 단계 대비 이탈률
  ROUND(SAFE_DIVIDE(reached, n0) * 100, 2)                                          AS of_all_sessions_pct
FROM c, UNNEST([
  STRUCT(0 AS step_no, 'session' AS step, n0 AS reached),
  STRUCT(1, 'view_item+',        n1),
  STRUCT(2, 'add_to_cart+',      n2),
  STRUCT(3, 'checkout+',         n3),
  STRUCT(4, 'add_payment_info+', n4),
  STRUCT(5, 'purchase',          n5)
])
ORDER BY step_no;
