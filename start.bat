@echo off
echo Starting SurrealDB v3.0.5 with RocksDB (persistent file-based storage)...
echo Listening on http://localhost:8000
echo Username: root / Password: root
echo.
surreal start --user root --pass root --bind 0.0.0.0:8000 --allow-net=llm.imonitorplus.com "rocksdb:///d:/LLM-repository/POC/surrealdb/data-rocksdb"
