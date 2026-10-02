#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LDN-AL20: 在内核中补回华为私有的 /proc/wifi_built_in/* 节点，
并增加开机自动 kickstart，使内置 prima WLAN 驱动不再依赖任何
root / Magisk / KernelSU 模块来拉起。

原厂链路（/vendor/etc/init/init.huawei.wcnss.rc）:
    service wlan_detect      (class main, oneshot, root)
    service wifi_driver_init (class late_start, oneshot, root, disabled)
    on property:wlan.driver.wcnss_service.state=running -> start wifi_driver_init
    on property:wlan.driver.trigger=start -> write /proc/wifi_built_in/wifi_start start

而 wlan_hdd_main.c 内置编译时 hdd_module_init() 故意 return 0，
等待用户态写 fwpath / con_mode 才 kickstart_driver()。
该 proc 节点属于华为私有内核代码，公开源码树里没有 -> 链路断裂 -> WiFi 永远起不来。

幂等：已打过补丁则直接退出。

用法：
    python3 wifi_proc_patch.py [内核源码树根目录]
    # 默认 $KSRC 或 ~/kernsrc
"""
import io
import os
import sys

KSRC = (sys.argv[1] if len(sys.argv) > 1
        else os.environ.get("KSRC") or os.path.expanduser("~/kernsrc"))
TARGET = os.path.join(KSRC, "drivers/prima/CORE/HDD/src/wlan_hdd_main.c")
MARK = "LDN-AL20-BUILTIN-WIFI-TRIGGER"

# ---------------------------------------------------------------- 1) includes
INC_ANCHOR = """#include <linux/etherdevice.h>
#include <linux/firmware.h>
"""

INC_NEW = """#include <linux/etherdevice.h>
#include <linux/firmware.h>
/* --- LDN-AL20-BUILTIN-WIFI-TRIGGER: stock trigger emulation --- */
#include <linux/proc_fs.h>
#include <linux/workqueue.h>
#include <linux/delay.h>
#include <linux/jiffies.h>
#include <linux/uaccess.h>
#ifndef MODULE
static int wifi_built_in_init(void);
#endif
/* --- end LDN-AL20-BUILTIN-WIFI-TRIGGER --- */
"""

# ------------------------------------------------- 2) proc 节点 + 自动启动
BODY_ANCHOR = """   ret = param_set_int(kmessage, kp);
   if (0 == ret)
      ret = kickstart_driver();
   return ret;
}
#endif /* #ifdef MODULE */
"""

BODY_NEW = """   ret = param_set_int(kmessage, kp);
   if (0 == ret)
      ret = kickstart_driver();
   return ret;
}
#endif /* #ifdef MODULE */

#ifndef MODULE
/* -------------------------------------------------------------------------
 * LDN-AL20-BUILTIN-WIFI-TRIGGER
 *
 * 复刻华为原厂 /proc/wifi_built_in/* 私有节点，让原厂 userspace 链路
 * (wlan_detect -> wifi_driver_init -> write wifi_start) 可以正常工作；
 * 同时自带开机自动 kickstart 兜底，即使 userspace 从不写该节点，
 * WLAN 驱动也能在开机后自动起来。
 *
 * 这样 WiFi 不再依赖 Magisk / KernelSU 模块或任何 root 脚本。
 * ------------------------------------------------------------------------- */

/* 真机验证可用的 con_mode 取值 */
#define WLAN_BI_START_CON_MODE 3

#define WLAN_BI_AUTOSTART_DELAY_MS 20000
#define WLAN_BI_RETRY_MS           10000
#define WLAN_BI_MAX_RETRY          6

static struct proc_dir_entry *wifi_built_in_dir;
static char wifi_built_in_mac_addr[32] = "00:00:00:00:00:00\\n";
static unsigned int wifi_built_in_debug_level;
static int wifi_built_in_retry;

static void wifi_built_in_kickstart(int mode)
{
	int ret;

	if (wlan_hdd_inited)
		return;

	/* 与原厂节点一致：先记录并发模式，再拉起驱动 */
	hdd_set_conparam((v_UINT_t)mode);

	ret = kickstart_driver();
	if (ret) {
		pr_err("%s: kickstart_driver failed: %d\\n", WLAN_MODULE_NAME, ret);
		return;
	}

	pr_info("%s: driver kicked off (con_mode=%d)\\n", WLAN_MODULE_NAME, mode);
}

static ssize_t wifi_built_in_start_write(struct file *file,
					 const char __user *buf,
					 size_t count, loff_t *ppos)
{
	char kbuf[32];
	size_t len;

	if (count == 0)
		return 0;

	len = min(count, sizeof(kbuf) - 1);
	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;
	kbuf[len] = '\\0';
	strim(kbuf);

	pr_info("%s: /proc/wifi_built_in/wifi_start <- '%s'\\n",
		WLAN_MODULE_NAME, kbuf);

	if (!strcmp(kbuf, "start") || !strcmp(kbuf, "1")) {
		wifi_built_in_kickstart(WLAN_BI_START_CON_MODE);
	} else if (!strcmp(kbuf, "stop") || !strcmp(kbuf, "0")) {
		if (wlan_hdd_inited) {
			hdd_driver_exit();
			wlan_hdd_inited = 0;
			pr_info("%s: driver stopped by wifi_built_in\\n",
				WLAN_MODULE_NAME);
		}
	}

	return count;
}

static ssize_t wifi_built_in_mac_read(struct file *file, char __user *buf,
				      size_t count, loff_t *ppos)
{
	return simple_read_from_buffer(buf, count, ppos, wifi_built_in_mac_addr,
				       strlen(wifi_built_in_mac_addr));
}

static ssize_t wifi_built_in_dbg_read(struct file *file, char __user *buf,
				      size_t count, loff_t *ppos)
{
	char tmp[16];
	int len;

	len = scnprintf(tmp, sizeof(tmp), "%u\\n", wifi_built_in_debug_level);
	return simple_read_from_buffer(buf, count, ppos, tmp, len);
}

static ssize_t wifi_built_in_dbg_write(struct file *file,
				       const char __user *buf,
				       size_t count, loff_t *ppos)
{
	char kbuf[16];
	size_t len;
	unsigned int val;

	if (count == 0)
		return 0;

	len = min(count, sizeof(kbuf) - 1);
	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;
	kbuf[len] = '\\0';

	if (kstrtouint(strim(kbuf), 10, &val) == 0)
		wifi_built_in_debug_level = val;

	return count;
}

static const struct file_operations wifi_built_in_start_fops = {
	.owner = THIS_MODULE,
	.write = wifi_built_in_start_write,
};

static const struct file_operations wifi_built_in_mac_fops = {
	.owner = THIS_MODULE,
	.read = wifi_built_in_mac_read,
};

static const struct file_operations wifi_built_in_dbg_fops = {
	.owner = THIS_MODULE,
	.read = wifi_built_in_dbg_read,
	.write = wifi_built_in_dbg_write,
};

static void wifi_built_in_autostart_fn(struct work_struct *work);

static DECLARE_DELAYED_WORK(wifi_built_in_autostart,
			    wifi_built_in_autostart_fn);

static void wifi_built_in_autostart_fn(struct work_struct *work)
{
	if (wlan_hdd_inited)
		return;

	wifi_built_in_kickstart(WLAN_BI_START_CON_MODE);

	if (!wlan_hdd_inited && wifi_built_in_retry < WLAN_BI_MAX_RETRY) {
		wifi_built_in_retry++;
		pr_info("%s: autostart retry %d/%d in %d ms\\n",
			WLAN_MODULE_NAME, wifi_built_in_retry,
			WLAN_BI_MAX_RETRY, WLAN_BI_RETRY_MS);
		schedule_delayed_work(&wifi_built_in_autostart,
				      msecs_to_jiffies(WLAN_BI_RETRY_MS));
	}
}

static int __init wifi_built_in_init(void)
{
	wifi_built_in_dir = proc_mkdir("wifi_built_in", NULL);
	if (!wifi_built_in_dir) {
		pr_err("%s: cannot create /proc/wifi_built_in\\n", WLAN_MODULE_NAME);
		return -ENOMEM;
	}

	proc_create("wifi_start", 0644, wifi_built_in_dir,
		    &wifi_built_in_start_fops);
	proc_create("mac_addr_hw", 0644, wifi_built_in_dir,
		    &wifi_built_in_mac_fops);
	proc_create("debug_level_hw", 0644, wifi_built_in_dir,
		    &wifi_built_in_dbg_fops);

	/* 兜底：即使 userspace 从不写 wifi_start，也在开机后自动拉起驱动 */
	schedule_delayed_work(&wifi_built_in_autostart,
			      msecs_to_jiffies(WLAN_BI_AUTOSTART_DELAY_MS));

	pr_info("%s: /proc/wifi_built_in ready, autostart in %d ms\\n",
		WLAN_MODULE_NAME, WLAN_BI_AUTOSTART_DELAY_MS);
	return 0;
}
#endif /* MODULE */
"""

# ------------------------------------------------------ 3) 挂到 module_init
INIT_ANCHOR = """static int __init hdd_module_init ( void)
{
   /* Driver initialization is delayed to fwpath_changed_handler */
   return 0;
}
"""

INIT_NEW = """static int __init hdd_module_init ( void)
{
   /* Driver initialization is delayed to fwpath_changed_handler */
   /* LDN-AL20-BUILTIN-WIFI-TRIGGER: 同时补上原厂 /proc/wifi_built_in 节点
      并安排开机自动 kickstart，使内置 WLAN 驱动无需 root 即可起来。 */
   wifi_built_in_init();
   return 0;
}
"""


def fail(msg):
    sys.stderr.write("[wifi_proc_patch] ERROR: %s\n" % msg)
    sys.exit(1)


def replace_once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        fail("锚点 [%s] 匹配到 %d 次（期望 1 次）" % (what, n))
    print("[wifi_proc_patch] patched: %s" % what)
    return text.replace(old, new, 1)


def main():
    if not os.path.isfile(TARGET):
        fail("找不到目标文件 %s" % TARGET)

    with io.open(TARGET, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if src.count(MARK) >= 3:
        print("[wifi_proc_patch] 已打过补丁，跳过。")
        return

    src = replace_once(src, INC_ANCHOR, INC_NEW, "includes")
    src = replace_once(src, BODY_ANCHOR, BODY_NEW, "proc 节点 + 自动启动")
    src = replace_once(src, INIT_ANCHOR, INIT_NEW, "hdd_module_init")

    with io.open(TARGET, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src)

    print("[wifi_proc_patch] 完成，标记数 = %d" % src.count(MARK))


if __name__ == "__main__":
    main()
