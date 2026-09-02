echo "===== UPTIME ====="
uptime
cat /proc/uptime
who -b
last reboot 2>/dev/null | head -20

echo "===== KERNEL ====="
dmesg -T | tail -300

echo "===== TEMPERATURA ====="
cat /proc/ubnthal/system.info 2>/dev/null
ubnt-fanctrl status 2>/dev/null

echo "===== WIFI ERRORS ====="
logread | grep -iE "panic|watchdog|reset|reboot|thermal|overheat|voltage|fatal|crash|oom|firmware|assert|exception"

echo "===== ECM/NSS ====="
logread | grep -iE "ECM|NSS|SFE|softirq|NOHZ"

echo "===== WIFI RETRIES ====="
logread | grep -iE "Excessive Retries|excessive retries|low_phy_rate|kickout|disassociated|deauthenticated"

echo "===== NTP/DNS ====="
logread | grep -iE "ntpd|DNS_TIMEOUT|DNS request timed out"
