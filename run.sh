#!/bin/bash

echo "Starting Python API on port 5000..."

cd ~/sentiment-analysis/python-ml-api
echo "Activating Python virtual environment..."
source ~/sentiment-analysis/.venv/bin/activate

uvicorn main:app --host 0.0.0.0 --port 5000 --reload &
PYTHON_PID=$!

sleep 3

echo "Starting Ruby Frontend on port 3000..."
cd ~/sentiment-analysis/rails-sentiment-app
ruby final.rb &
RUBY_PID=$!

echo "Both servers are running:"
echo " - Python API on http://localhost:5000"
echo " - Ruby Frontend on http://localhost:3000"

trap "echo Stopping...; kill $PYTHON_PID; kill $RUBY_PID; exit" INT

wait

