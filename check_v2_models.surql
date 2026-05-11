OPTION IMPORT;

USE NS vitasales;
USE DB vitasales;

-- Check all v2.0.0 models
SELECT model_name, version FROM model_definition WHERE version = '2.0.0' ORDER BY model_name;
