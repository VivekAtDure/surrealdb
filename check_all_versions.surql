OPTION IMPORT;

USE NS vitasales;
USE DB vitasales;

-- Query 1: Check all consumer_score models
SELECT id, model_name, version, surrealdb_ml_name, is_active, created_at FROM model_definition WHERE model_name = 'consumer_score' ORDER BY version DESC;

-- Query 2: Count total versions
SELECT COUNT() as total_versions FROM model_definition WHERE model_name = 'consumer_score' GROUP ALL;

-- Query 3: Get all model records (see full details)
SELECT * FROM model_definition WHERE model_name = 'consumer_score';
