-- =============================================================
-- Tech ABC Corp HR Database
-- PostgreSQL DDL + ETL + CRUD Script
-- =============================================================

-- DROP & CREATE DATABASE
-- (Run DROP/CREATE commands as a superuser outside this script
--  or simply connect to an existing database and run from here)

CREATE DATABASE techabc_hr;

-- Connect to the new database before running the rest:
\c techabc_hr

-- SECTION 1: CREATE LOOKUP TABLES

CREATE TABLE department (
    dept_id     SERIAL       NOT NULL,
    dept_nm     VARCHAR(50)  NOT NULL,
    CONSTRAINT pk_department PRIMARY KEY (dept_id),
    CONSTRAINT uq_dept_nm UNIQUE (dept_nm)
);

CREATE TABLE job_title (
    title_id    SERIAL       NOT NULL,
    title_nm    VARCHAR(100) NOT NULL,
    CONSTRAINT pk_job_title PRIMARY KEY (title_id),
    CONSTRAINT uq_title_nm UNIQUE (title_nm)
);

CREATE TABLE location (
    location_id  SERIAL       NOT NULL,
    location_nm  VARCHAR(50)  NOT NULL,
    city         VARCHAR(50)  NOT NULL,
    state        CHAR(2)      NOT NULL,
    CONSTRAINT pk_location PRIMARY KEY (location_id),
    CONSTRAINT uq_location_nm UNIQUE (location_nm)
);

CREATE TABLE education_level (
    edu_id      SERIAL       NOT NULL,
    edu_level   VARCHAR(50)  NOT NULL,
    CONSTRAINT pk_education_level PRIMARY KEY (edu_id),
    CONSTRAINT uq_edu_level UNIQUE (edu_level)
);

-- SECTION 2: CREATE CORE TABLES

CREATE TABLE employee (
    emp_id      VARCHAR(10)  NOT NULL,
    emp_nm      VARCHAR(100) NOT NULL,
    email       VARCHAR(150) NOT NULL,
    hire_dt     DATE         NOT NULL,
    dept_id     INT          NOT NULL,
    manager_nm  VARCHAR(100) NULL,
    location_id INT          NOT NULL,
    address     VARCHAR(150) NULL,
    city        VARCHAR(50)  NULL,
    state       CHAR(2)      NULL,
    edu_id      INT          NULL,
    CONSTRAINT pk_employee PRIMARY KEY (emp_id)
);

-- salary is in this table, separated from employee
-- to enforce column-level security via GRANT/REVOKE
CREATE TABLE employee_job_history (
    history_id  SERIAL        NOT NULL,
    emp_id      VARCHAR(10)   NOT NULL,
    title_id    INT           NOT NULL,
    salary      NUMERIC(10,2) NOT NULL,
    start_dt    DATE          NOT NULL,
    end_dt      DATE          NULL,
    CONSTRAINT pk_emp_job_history PRIMARY KEY (history_id)
);

-- SECTION 3: ADD FOREIGN KEY CONSTRAINTS

ALTER TABLE employee
    ADD CONSTRAINT fk_emp_dept
    FOREIGN KEY (dept_id) REFERENCES department(dept_id);

ALTER TABLE employee
    ADD CONSTRAINT fk_emp_location
    FOREIGN KEY (location_id) REFERENCES location(location_id);

ALTER TABLE employee
    ADD CONSTRAINT fk_emp_edu
    FOREIGN KEY (edu_id) REFERENCES education_level(edu_id);

ALTER TABLE employee_job_history
    ADD CONSTRAINT fk_history_emp
    FOREIGN KEY (emp_id) REFERENCES employee(emp_id);

ALTER TABLE employee_job_history
    ADD CONSTRAINT fk_history_title
    FOREIGN KEY (title_id) REFERENCES job_title(title_id);

-- SECTION 4: CREATE VIEWS

-- Public view: no salary data
-- GRANT SELECT on this view to all domain users
CREATE OR REPLACE VIEW vw_employee_public AS
SELECT
    e.emp_id,
    e.emp_nm,
    e.email,
    e.hire_dt,
    jt.title_nm      AS job_title,
    d.dept_nm        AS department,
    e.manager_nm,
    l.location_nm    AS location,
    l.city           AS office_city,
    l.state          AS office_state,
    edu.edu_level    AS education_level
FROM employee e
JOIN department d           ON e.dept_id     = d.dept_id
JOIN location l             ON e.location_id = l.location_id
LEFT JOIN education_level edu ON e.edu_id    = edu.edu_id
JOIN employee_job_history h ON e.emp_id      = h.emp_id
    AND h.end_dt IS NULL
JOIN job_title jt           ON h.title_id    = jt.title_id;

-- Full view: includes salary
-- GRANT SELECT on this view to HR and management roles only
CREATE OR REPLACE VIEW vw_employee_full AS
SELECT
    e.emp_id,
    e.emp_nm,
    e.email,
    e.hire_dt,
    jt.title_nm      AS job_title,
    d.dept_nm        AS department,
    e.manager_nm,
    l.location_nm    AS location,
    h.salary,
    h.start_dt,
    h.end_dt,
    edu.edu_level    AS education_level
FROM employee e
JOIN department d            ON e.dept_id     = d.dept_id
JOIN location l              ON e.location_id = l.location_id
LEFT JOIN education_level edu ON e.edu_id     = edu.edu_id
JOIN employee_job_history h  ON e.emp_id      = h.emp_id
    AND h.end_dt IS NULL
JOIN job_title jt            ON h.title_id    = jt.title_id;

-- create and populate staging table proj_stg
\i /home/workspace/StageTableLoad.sql

--ETL - Populate tables from staging table proj_stg

-- a: department
INSERT INTO department (dept_nm)
SELECT DISTINCT(department_nm) 
FROM proj_stg;

-- Verify
SELECT * FROM department;


-- b: job_title
INSERT INTO job_title (title_nm)
SELECT DISTINCT(job_title) 
FROM proj_stg;

-- Verify
SELECT * FROM job_title;


-- c: location
-- matching staging row (consistent across all rows per location)
INSERT INTO location (location_nm, city, state)
SELECT
    location, -- Add this back in to match location_nm
    CASE WHEN city = 'Minnapolis' THEN 'Minneapolis' ELSE city END AS city,
    state
FROM (
    SELECT DISTINCT ON (location) location, city, state
    FROM proj_stg
) loc_dedup
ORDER BY location;
-- Verify (Minneapolis should be spelled correctly)
SELECT * FROM location;

-- d: education_level
INSERT INTO education_level (edu_id, edu_level)
SELECT DISTINCT
    ROW_NUMBER() OVER (ORDER BY
        CASE education_lvl
            WHEN 'No College'                        THEN 1
            WHEN 'Some College'                      THEN 2
            WHEN 'Associates Degree'                 THEN 3
            WHEN 'Bachelors Degree'                  THEN 4
            WHEN 'Masters Degree'                    THEN 5
            WHEN 'Masters of Business Administration' THEN 6
            WHEN 'Doctorate'                         THEN 7
            ELSE 8
        END
    ) AS edu_id,
    education_lvl AS edu_level
FROM proj_stg
ON CONFLICT (edu_level) DO NOTHING;

-- Verify
SELECT * FROM education_level;

-- e: employee
-- Only one row per emp_id is inserted into employee (the most
-- recent / current record, identified by the MAX hire_dt).
-- Lookup FKs are resolved via JOIN to the lookup tables

INSERT INTO employee (
    emp_id, emp_nm, email, hire_dt,
    dept_id, manager_nm, location_id,
    address, city, state, edu_id
)
SELECT DISTINCT ON (s.emp_id)
    s.emp_id,
    TRIM(s.emp_nm)                      AS emp_nm,
    TRIM(s.email)                       AS email,
    s.hire_dt,
    d.dept_id,
    NULLIF(TRIM(s.manager), '#N/A')     AS manager_nm,
    l.location_id,
    TRIM(s.address)                     AS address,
    -- Correct 'Minnapolis' typo carried through from source
    CASE WHEN TRIM(s.city) = 'Minnapolis'
         THEN 'Minneapolis'
         ELSE TRIM(s.city)
    END                                 AS city,
    s.state,
    edu.edu_id
FROM proj_stg s
JOIN department     d   ON TRIM(s.department_nm)  = d.dept_nm
JOIN location       l   ON TRIM(s.location)        = l.location_nm
LEFT JOIN education_level edu ON TRIM(s.education_lvl) = edu.edu_level
ORDER BY s.emp_id, s.hire_dt DESC;   -- DISTINCT ON keeps the most-recent row per emp_id

-- Verify
SELECT COUNT(*) AS total_employees FROM employee; 

-- f: employee_job_history
-- LOAD employee_job_history TABLE FROM STAGING
-- All 205 staging rows are loaded (199 current + 6 historical).
INSERT INTO employee_job_history (
    emp_id, title_id, salary, start_dt, end_dt
)
SELECT
    s.emp_id,
    jt.title_id,
    CAST(s.salary AS NUMERIC(10,2))     AS salary,
    s.start_dt,
    -- Convert sentinel 2100-xx-xx dates back to NULL (= currently active)
    CASE WHEN s.end_dt >= '2100-01-01'
         THEN NULL
         ELSE s.end_dt
    END                                 AS end_dt
FROM proj_stg s
JOIN job_title jt ON TRIM(s.job_title) = jt.title_nm
ORDER BY s.emp_id, s.start_dt;

-- Verify totals
SELECT COUNT(*)                         AS total_history_rows  FROM employee_job_history;  
SELECT COUNT(*) FILTER (WHERE end_dt IS NULL)  AS current_positions FROM employee_job_history;  
SELECT COUNT(*) FILTER (WHERE end_dt IS NOT NULL) AS past_positions  FROM employee_job_history;

-- SECTION: CRUD QUESTIONS

-- Q1: Return a list of employees with Job Titles and
--     Department Names
SELECT
    e.emp_id,
    e.emp_nm          AS employee_name,
    jt.title_nm       AS job_title,
    d.dept_nm         AS department
FROM employee e
JOIN department d            ON e.dept_id  = d.dept_id
JOIN employee_job_history h  ON e.emp_id   = h.emp_id
    AND h.end_dt IS NULL
JOIN job_title jt            ON h.title_id = jt.title_id
ORDER BY d.dept_nm, e.emp_nm;


-- Q2: Insert Web Programmer as a new job title
INSERT INTO job_title (title_nm)
VALUES ('Web Programmer');

-- Verify the insert
SELECT * FROM job_title ORDER BY title_id;


-- Q3: Correct the job title from Web Programmer to
--     Web Developer
UPDATE job_title
SET    title_nm = 'Web Developer'
WHERE  title_nm = 'Web Programmer';

-- Verify the update
SELECT * FROM job_title ORDER BY title_id;

-- Q4: Delete the job title Web Developer from the database
DELETE FROM job_title
WHERE  title_nm = 'Web Developer';

-- Verify the delete
SELECT * FROM job_title ORDER BY title_id;

-- Q5: How many employees are in each department?
SELECT
    d.dept_nm        AS department,
    COUNT(e.emp_id)  AS employee_count
FROM employee e
JOIN department d ON e.dept_id = d.dept_id
GROUP BY d.dept_nm
ORDER BY employee_count DESC;

-- Q6: Current and past jobs for employee Toni Lembeck
--     (employee name, job title, department, manager name,
--      start and end date)
SELECT
    e.emp_nm          AS employee_name,
    jt.title_nm       AS job_title,
    d.dept_nm         AS department,
    e.manager_nm,
    h.start_dt,
    h.end_dt,
    CASE
        WHEN h.end_dt IS NULL THEN 'Current'
        ELSE 'Past'
    END               AS position_status
FROM employee e
JOIN employee_job_history h ON e.emp_id   = h.emp_id
JOIN job_title jt           ON h.title_id = jt.title_id
JOIN department d           ON e.dept_id  = d.dept_id
WHERE e.emp_nm = 'Toni Lembeck'
ORDER BY h.start_dt;

-- ----------------------------------------------------------
-- Q7: Applying table security to restrict salary access
--     in PostgreSQL
-- see ppt presentation for description and step-by-step instructions

--**********Standout session**********--

-- Standout QUESTION 1
-- Create a view that returns all employee attributes;
-- results should resemble the initial Excel file

CREATE OR REPLACE VIEW vw_excel_replica AS
SELECT
    e.emp_id                        AS "EMP_ID",
    e.emp_nm                        AS "EMP_NM",
    e.email                         AS "EMAIL",
    e.hire_dt                       AS "HIRE_DT",
    jt.title_nm                     AS "JOB_TITLE",
    h.salary                        AS "SALARY",
    d.dept_nm                       AS "DEPARTMENT",
    e.manager_nm                    AS "MANAGER",
    h.start_dt                      AS "START_DT",
    h.end_dt                        AS "END_DT",
    l.location_nm                   AS "LOCATION",
    e.address                       AS "ADDRESS",
    e.city                          AS "CITY",
    e.state                         AS "STATE",
    edu.edu_level                   AS "EDUCATION LEVEL"
FROM employee e
JOIN department d             ON e.dept_id     = d.dept_id
JOIN location l               ON e.location_id = l.location_id
LEFT JOIN education_level edu ON e.edu_id      = edu.edu_id
JOIN employee_job_history h   ON e.emp_id      = h.emp_id
JOIN job_title jt             ON h.title_id    = jt.title_id
ORDER BY e.emp_id, h.start_dt;

-- Verify: should return 205 rows matching the original Excel
SELECT * FROM vw_excel_replica;


-- Standout QUESTION 2
-- Stored procedure with parameters that returns current AND
-- past jobs for a given employee name:
--   - Employee Name
--   - Job Title
--   - Department
--   - Manager Name
--   - Start Date
--   - End Date

CREATE OR REPLACE FUNCTION sp_get_employee_job_history(
    p_emp_nm VARCHAR(100)
)
RETURNS TABLE (
    employee_name   VARCHAR(100),
    job_title       VARCHAR(100),
    department      VARCHAR(50),
    manager_name    VARCHAR(100),
    start_date      DATE,
    end_date        DATE,
    position_status TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.emp_nm                            AS employee_name,
        jt.title_nm                         AS job_title,
        d.dept_nm                           AS department,
        e.manager_nm                        AS manager_name,
        h.start_dt                          AS start_date,
        h.end_dt                            AS end_date,
        CASE
            WHEN h.end_dt IS NULL THEN 'Current'
            ELSE 'Past'
        END::TEXT                           AS position_status
    FROM employee e
    JOIN employee_job_history h ON e.emp_id   = h.emp_id
    JOIN job_title jt           ON h.title_id = jt.title_id
    JOIN department d           ON e.dept_id  = d.dept_id
    WHERE e.emp_nm ILIKE p_emp_nm           -- ILIKE = case-insensitive match
    ORDER BY h.start_dt;

    -- If no rows were found, raise a helpful notice
    IF NOT FOUND THEN
        RAISE NOTICE 'No employee found matching name: %', p_emp_nm;
    END IF;
END;
$$;

-- Test the stored procedure: call with Toni Lembeck
-- Expected: 2 rows — past Network Engineer + current DBA
SELECT * FROM sp_get_employee_job_history('Toni Lembeck');


-- Standout QUESTION 3
-- Implement user security on the restricted salary attribute.
-- Create a non-management user NoMgr, grant database access,
-- but revoke access to salary data.

-- Step 1: Create the NoMgr user (role with login)
CREATE ROLE "NoMgr" WITH LOGIN PASSWORD 'TechABC_2026!';

-- Step 2: Grant connection to the database
GRANT CONNECT ON DATABASE techabc_hr TO "NoMgr";

-- Step 3: Grant usage on the public schema
GRANT USAGE ON SCHEMA public TO "NoMgr";

-- Step 4: Grant SELECT on all non-sensitive tables
GRANT SELECT ON employee          TO "NoMgr";
GRANT SELECT ON department        TO "NoMgr";
GRANT SELECT ON job_title         TO "NoMgr";
GRANT SELECT ON location          TO "NoMgr";
GRANT SELECT ON education_level   TO "NoMgr";

-- Step 5: Grant SELECT on employee_job_history for all columns
--         EXCEPT salary using column-level privileges.
--         PostgreSQL supports per-column GRANTs — list every
--         column explicitly, omitting salary.
GRANT SELECT (
    history_id,
    emp_id,
    title_id,
    start_dt,
    end_dt
) ON employee_job_history TO "NoMgr";
-- salary column is intentionally omitted — NoMgr cannot
-- SELECT it directly from the table.

-- Step 6: Grant access to the public view (salary excluded)
GRANT SELECT ON vw_employee_public TO "NoMgr";

-- Step 7: Explicitly revoke access to the full view
--         and the salary column as a safety backstop.
--         Even if NoMgr is later added to a group that has
--         broader access, these REVOKEs remain in effect.
REVOKE SELECT ON vw_employee_full FROM "NoMgr";
REVOKE SELECT (salary) ON employee_job_history FROM "NoMgr";

-- Verification: review what NoMgr can and cannot do
-- This query checks all privileges granted to NoMgr
-- across tables and columns in the public schema:
SELECT
    grantee,
    table_name,
    column_name,
    privilege_type
FROM information_schema.column_privileges
WHERE grantee = 'NoMgr'
ORDER BY table_name, column_name;

-- Table-level privileges for NoMgr
SELECT
    grantee,
    table_name,
    privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'NoMgr'
ORDER BY table_name;


--BLOCKED for NoMgr:

-- Set role within the same session (test)
SET ROLE "NoMgr";

-- Now run the blocked queries
SELECT salary FROM employee_job_history;      -- ERROR: permission denied
SELECT * FROM employee_job_history;           -- ERROR: permission denied
SELECT * FROM vw_employee_full;               -- ERROR: permission denied
--******************************************************************--    
