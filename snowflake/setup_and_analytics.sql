-- Compute: smallest size, shuts off after 60 seconds idle
CREATE WAREHOUSE IF NOT EXISTS fleetpulse_wh
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60;
USE WAREHOUSE fleetpulse_wh;

-- Folders
CREATE DATABASE IF NOT EXISTS fleetpulse;
CREATE SCHEMA IF NOT EXISTS fleetpulse.analytics;
USE SCHEMA fleetpulse.analytics;

-- Landing zone for your CSVs
CREATE STAGE IF NOT EXISTS fleetpulse_stage
  FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"');

-- Tables
CREATE OR REPLACE TABLE dim_robot (
  robot_id INT, model STRING, site STRING, deploy_date DATE);

CREATE OR REPLACE TABLE failure_log (
  failure_id INT, robot_id INT, start_ts TIMESTAMP_NTZ,
  end_ts TIMESTAMP_NTZ, failure_type STRING);

CREATE OR REPLACE TABLE fact_robot_hourly (
  robot_id INT, model STRING, hour TIMESTAMP_NTZ,
  battery_pct FLOAT, motor_temp_c FLOAT, loc_error_cm FLOAT,
  z_temp FLOAT, z_loc FLOAT, z_batt FLOAT,
  is_anomaly BOOLEAN, is_alert BOOLEAN);



COPY INTO dim_robot FROM @fleetpulse_stage PATTERN = '.*robots.*';
COPY INTO failure_log FROM @fleetpulse_stage PATTERN = '.*failure_log.*';
COPY INTO fact_robot_hourly FROM @fleetpulse_stage PATTERN = '.*gold.*';

SELECT 'dim_robot' AS t, COUNT(*) FROM dim_robot
UNION ALL SELECT 'failure_log', COUNT(*) FROM failure_log
UNION ALL SELECT 'fact_robot_hourly', COUNT(*) FROM fact_robot_hourly;


-- query 1: Which robots need attention first? --
-- joins the fact table to the dimension table to get each robot's model & site, counts its alert hours and ranks them -- 
SELECT r.robot_id, r.model, r.site,
       COUNT_IF(f.is_alert) AS alert_hours,
       ROUND(MAX(f.motor_temp_c), 1) AS max_temp_c
FROM fact_robot_hourly f
JOIN dim_robot r ON f.robot_id = r.robot_id
GROUP BY r.robot_id, r.model, r.site
HAVING alert_hours > 0
ORDER BY alert_hours DESC
LIMIT 10;


-- query 2: which warehouse sites are healthiest --
/*
The same data rolled up from robots to sites, which is what a manager would look at. IFF is Snowflake’s if/else: “if alert, the robot’s id, otherwise nothing.”
*/
SELECT r.site,
       COUNT(DISTINCT r.robot_id) AS robots,
       COUNT(DISTINCT IFF(f.is_alert, f.robot_id, NULL)) AS robots_with_alerts,
       ROUND(100 * COUNT_IF(f.is_alert) / COUNT(*), 3) AS pct_alert_hours
FROM fact_robot_hourly f
JOIN dim_robot r ON f.robot_id = r.robot_id
GROUP BY r.site
ORDER BY pct_alert_hours DESC;


-- query 3: how fast do we catch each failure type --
WITH detect AS (
  SELECT fl.failure_id, fl.failure_type, fl.start_ts,
         DATEADD('hour', 1, MIN(f.hour)) AS alert_known_at
  FROM failure_log fl
  LEFT JOIN fact_robot_hourly f
    ON f.robot_id = fl.robot_id
   AND f.is_alert
   AND f.hour >= DATE_TRUNC('hour', fl.start_ts)
   AND f.hour <= fl.end_ts
  GROUP BY fl.failure_id, fl.failure_type, fl.start_ts
)
SELECT failure_type,
       COUNT(*) AS failures,
       COUNT(alert_known_at) AS caught,
       ROUND(AVG(DATEDIFF('minute', start_ts, alert_known_at))) AS avg_minutes_to_detect
FROM detect
GROUP BY failure_type
ORDER BY avg_minutes_to_detect;

/*
WITH detect AS (...) is a CTE: a named temporary result you can query like a table. It makes long queries readable in steps.

Why add one hour: an hour labeled 2:00 holds data from 2:00 to 3:00, so you can’t actually know about the alert until 3:00. Without that, you’d be claiming detection before the data existed. 

Being honest about that timing is the kind of detail that impresses interviewers.
*/