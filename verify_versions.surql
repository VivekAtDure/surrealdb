OPTION IMPORT;

USE NS vitasales;
USE DB vitasales;

-- View all versions of consumer_score
SELECT id, model_name, version, surrealdb_ml_name, is_active FROM model_definition WHERE model_name = 'consumer_score';
