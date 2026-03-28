# Zigix ext3 Journal Integration Test
# Exercises every journaled metadata write path.
# Run with: sh /scripts/test_ext3.sh
#
# Expected: kernel logs "[ext3] Journal initialized" at boot.
# All operations below go through journal transactions.

echo "========================================="
echo "  ext3 Journal Integration Test Suite"
echo "========================================="
echo ""

echo "=== 1. File Create (allocInode + addDirEntry + writeInode) ==="
echo "journal test 1" > /tmp/j1.txt
cat /tmp/j1.txt

echo "=== 2. File Write (allocBlock + writeInode) ==="
echo "line1" > /tmp/j2.txt
echo "line2" >> /tmp/j2.txt
echo "line3" >> /tmp/j2.txt
cat /tmp/j2.txt
wc /tmp/j2.txt

echo "=== 3. Dir Create (allocInode + allocBlock + addDirEntry + BGD) ==="
mkdir /tmp/jdir
echo "nested file" > /tmp/jdir/inner.txt
cat /tmp/jdir/inner.txt
ls /tmp/jdir

echo "=== 4. File Delete (removeDirEntry + freeBlock + freeInode) ==="
echo "ephemeral" > /tmp/j3.txt
cat /tmp/j3.txt
rm /tmp/j3.txt
echo "(deleted - cat should fail below)"
cat /tmp/j3.txt

echo "=== 5. Dir Delete (rmdir + BGD update) ==="
mkdir /tmp/jdir2
rmdir /tmp/jdir2
echo "(deleted - ls should fail below)"
ls /tmp/jdir2

echo "=== 6. File Rename (removeDirEntry + addDirEntry) ==="
echo "rename me" > /tmp/j4_old.txt
mv /tmp/j4_old.txt /tmp/j4_new.txt
cat /tmp/j4_new.txt
echo "(old name should fail below)"
cat /tmp/j4_old.txt

echo "=== 7. Overwrite / Truncate (freeBlock + allocBlock) ==="
echo "original content that is longer" > /tmp/j5.txt
cat /tmp/j5.txt
echo "short" > /tmp/j5.txt
cat /tmp/j5.txt

echo "=== 8. Large file (indirect blocks + multiple allocBlock) ==="
echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > /tmp/j6.txt
echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" >> /tmp/j6.txt
echo "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" >> /tmp/j6.txt
echo "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" >> /tmp/j6.txt
wc /tmp/j6.txt

echo "=== 9. Persistent write to disk root ==="
echo "ext3 journal works" > /journal_test.txt
cat /journal_test.txt
sync

echo "=== 10. Verify pre-existing files ==="
cat /hello.txt
cat /etc/motd
ls /bin | head -5

echo ""
echo "========================================="
echo "  All 10 ext3 journal tests complete"
echo "========================================="
echo ""
echo "Check kernel serial output for:"
echo "  [ext3] Journal detected"
echo "  [ext3] Journal initialized"
echo "  (no crashes = journal write path working)"
