echo "=== Test 1: Create file in /tmp ==="
echo "hello tmpfs" > /tmp/test.txt
cat /tmp/test.txt

echo "=== Test 2: Overwrite file (O_TRUNC) ==="
echo "overwritten" > /tmp/test.txt
cat /tmp/test.txt

echo "=== Test 3: Append to file ==="
echo "line2" >> /tmp/test.txt
cat /tmp/test.txt

echo "=== Test 4: Create directory in /tmp ==="
mkdir /tmp/subdir
echo "nested" > /tmp/subdir/nested.txt
cat /tmp/subdir/nested.txt

echo "=== Test 5: Delete file ==="
rm /tmp/test.txt
cat /tmp/test.txt

echo "=== Test 6: List /tmp ==="
ls /tmp

echo "=== All tmpfs tests complete ==="
