## Default — 3 minutes, 10 concurrent
python demo_load_test.py

## Queue depth spike — useful to demonstrate num_requests_waiting trigger
python demo_load_test.py --mode queue --duration 120 --concurrency 20

## KV cache spike — useful to demonstrate memory pressure trigger
python demo_load_test.py --mode kv --duration 180 --concurrency 8

## Full demo — both triggers, longer duration
python demo_load_test.py --mode combined --duration 300 --concurrency 12
