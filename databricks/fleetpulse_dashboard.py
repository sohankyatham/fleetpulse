import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()  # already logged in, since the app runs inside Snowflake
session.use_warehouse("FLEETPULSE_WH")
session.use_schema("FLEETPULSE.ANALYTICS")

def q(sql):
    return session.sql(sql).to_pandas()

st.title("FleetPulse: Robot Fleet Health")
st.caption("500 simulated warehouse robots, October 2026")

# 1. Headline numbers
k = q("""
    SELECT COUNT(DISTINCT robot_id) AS robots,
           COUNT(DISTINCT IFF(is_alert, robot_id, NULL)) AS robots_alerting,
           COUNT_IF(is_alert) AS alert_hours
    FROM fact_robot_hourly
""")
c1, c2, c3 = st.columns(3)
c1.metric("Robots monitored", int(k.ROBOTS[0]))
c2.metric("Robots with alerts", int(k.ROBOTS_ALERTING[0]))
c3.metric("Alert hours", int(k.ALERT_HOURS[0]))

# 2. Alerts by site
st.subheader("Alert hours by site")
sites = q("""
    SELECT r.site AS site, COUNT_IF(f.is_alert) AS alert_hours
    FROM fact_robot_hourly f JOIN dim_robot r ON f.robot_id = r.robot_id
    GROUP BY r.site ORDER BY alert_hours DESC
""")
st.bar_chart(sites, x="SITE", y="ALERT_HOURS")

# 3. Robots needing attention
st.subheader("Robots needing attention")
top = q("""
    SELECT f.robot_id, r.model, r.site, COUNT_IF(f.is_alert) AS alert_hours
    FROM fact_robot_hourly f JOIN dim_robot r ON f.robot_id = r.robot_id
    GROUP BY f.robot_id, r.model, r.site
    HAVING alert_hours > 0
    ORDER BY alert_hours DESC
""")
st.dataframe(top, use_container_width=True)

# 4. Drill into one robot
st.subheader("Robot drill-down")
robot = st.selectbox("Pick a robot", top.ROBOT_ID.tolist())
hist = q(f"""
    SELECT hour, motor_temp_c, battery_pct, loc_error_cm, is_alert
    FROM fact_robot_hourly WHERE robot_id = {int(robot)} ORDER BY hour
""")
sensor = st.radio("Sensor", ["MOTOR_TEMP_C", "BATTERY_PCT", "LOC_ERROR_CM"], horizontal=True)
st.line_chart(hist, x="HOUR", y=sensor)
st.write("Hours with alerts:")
st.dataframe(hist[hist.IS_ALERT][["HOUR"]])