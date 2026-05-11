OPTION IMPORT;

USE NS vitasales;
USE DB vitasales;

-- Display all consumer_score versions
SELECT model_name, version, surrealdb_ml_name FROM model_definition WHERE model_name = 'consumer_score' ORDER BY version;
