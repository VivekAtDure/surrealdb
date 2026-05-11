OPTION IMPORT;

USE NS vitasales;
USE DB vitasales;

-- Count all consumer_score models
LET $result = (SELECT count() FROM model_definition WHERE model_name = 'consumer_score' GROUP ALL)[0].count;
$result;
