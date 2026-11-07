-- =========================================================
-- 06_fact_transactions.sql
-- 용도: Power BI 매출 팩트 테이블 (거래 1건 = 1행)
-- 데이터: bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*
--        (2020-11-01 ~ 2021-01-31)
-- 규칙
--   거래 식별: transaction_id 기준, NULL·'(not set)' 제외 (Day 9)
--   중복 거래: 같은 transaction_id는 가장 먼저 찍힌 이벤트 1건만 사용 (Day 11)
--   날짜·채널·기기: 거래가 발생한 세션 기준, 05_fact_daily_channel_device와 같은 규칙
-- 검증: 4,451행 / 매출 $307,640 / 객단가 $69.12
--       (desktop $69.77 / mobile $68.45, 기기 간 차이 없음)
-- 주의
--   - 거래 ID 식별분만 센 보수적 매출. purchase 이벤트 5,692건 중
--     transaction_id 없는 906건(15.9%)은 빠져 있음
--   - 거래 ID 미수집 구간: 11/1~11/10 전부, 11/11 일부, 1/26~1/31
--     → 일별 매출·객단가 차트는 11/12~1/25만 사용 (Power BI dim_date.revenue_tracked)
--   - 전환율은 세션 팩트(05) 기준이라 이 미수집의 영향 없음
-- =========================================================

WITH ev AS (
  SELECT
    user_pseudo_id,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS sid,
    event_date,
    event_timestamp,
    event_name,
    device.category                                                                     AS device,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'medium')        AS medium,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'source')        AS source,
    ecommerce.transaction_id                                                            AS transaction_id,
    ecommerce.purchase_revenue                                                          AS revenue
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

s AS (
  -- 세션 속성 (날짜·기기·채널): 05번과 같은 규칙으로 계산해야 두 팩트 테이블이 맞물림
  SELECT
    user_pseudo_id,
    sid,
    PARSE_DATE('%Y%m%d', MIN(event_date)) AS session_date,  -- 세션 시작일
    ANY_VALUE(device)                     AS device,        -- 세션당 1개 확인됨 (Day 8)
    -- 세션 내 값이 있는 첫 medium·source (Day 7 첫 값 규칙)
    ARRAY_AGG(IF(medium IS NULL, NULL, STRUCT(medium, source))
              IGNORE NULLS ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS first_ms
  FROM ev
  GROUP BY 1, 2
),

p AS (
  -- purchase 이벤트를 거래 단위로 정리
  -- 이벤트 단순합 매출은 $362,165로 약 15% 과대 (거래 ID 없음 + 중복 전송)
  SELECT
    user_pseudo_id,
    sid,
    transaction_id,
    revenue,
    -- 같은 거래 ID가 여러 번 찍힌 경우(326건, 금액 불일치 15건) 첫 이벤트만 사용
    -- 재전송 중복은 첫 이벤트가 실제 거래라고 판단.
    -- Day 9에는 MAX 금액으로 계산해 $308,200이었으나 Day 11에 첫 이벤트로 통일
    ROW_NUMBER() OVER (PARTITION BY transaction_id ORDER BY event_timestamp) AS rn
  FROM ev
  WHERE event_name = 'purchase'
    AND transaction_id IS NOT NULL
    AND transaction_id != '(not set)'
)

SELECT
  p.transaction_id,
  s.session_date,
  CASE
    WHEN s.first_ms IS NULL THEN '(missing)'
    -- 자기 도메인 referral은 외부 유입이 아님 (교차 도메인 설정 누락 추정)
    WHEN s.first_ms.medium = 'referral'
         AND s.first_ms.source LIKE '%googlemerchandisestore.com%' THEN 'referral_self'
    ELSE s.first_ms.medium
  END AS channel,
  s.device,
  p.revenue
FROM p
JOIN s USING (user_pseudo_id, sid)  -- 거래가 일어난 세션의 속성을 붙임
WHERE p.rn = 1                       -- 거래 1건 = 1행
ORDER BY s.session_date, p.transaction_id;
