echo "=== Test 1: Background job ==="
ztrue &
jobs

echo "=== Test 2: kill builtin ==="
echo "Sending SIGTERM to PID 1 (should fail gracefully)"
kill -15 999

echo "=== Test 3: Job control commands ==="
echo "Manual tests:"
echo "  1. Run 'cat' then press Ctrl-C -> should terminate"
echo "  2. Run 'cat' then press Ctrl-Z -> should show Stopped"
echo "  3. Run 'jobs' -> should list stopped job"
echo "  4. Run 'fg %1' -> should resume cat"
echo "  5. Press Ctrl-C -> should terminate cat"

echo "=== All automated tests complete ==="
