#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0
#
# l410-fprintd-shim - a net.reactivated.Fprint (fprintd) D-Bus service that
# proxies to the Huawei fingerprint daemon on the L410.
#
# Why a shim and not a libfprint driver:
#   * On this machine SPI1 belongs to the iTrustee TrustZone, so userspace
#     (libfprint) can never read the sensor.  The image is captured by the TA
#     inside the TEE and matched there as well; only the vendor daemon
#     (com.huawei.Fingerprint) can ask it to enroll/identify.
#   * libfprint drivers use a private, version-specific API and must be built
#     into libfprint.  The fprintd D-Bus API, on the other hand, is stable and
#     documented, and everything that matters (KDE/GNOME settings, fprintd-*
#     command line tools, pam_fprintd -> login/sudo/lock screen) speaks it.
#
# The interface implemented here is exactly fprintd 1.94.5's
# src/net.reactivated.Fprint.{Manager,Device}.xml.
#
# Mapping:
#   Claim/Release                  -> StartSession / Close / SearchDevice
#   EnrollStart(finger)            -> Enroll(template_db_path, username)
#   VerifyStart(finger)/VerifyStop -> Identify(username)  (blocking in the TA)
#   ListEnrolledFingers            -> our own bookkeeping + SFS template db
#   EnrollStatus/VerifyStatus      -> emitted from the daemon's log +
#                                     the return value of Enroll/Identify

import json
import os
import pwd
import re
import threading
import time

from gi.repository import Gio, GLib

BUS_NAME = "net.reactivated.Fprint"
MANAGER_PATH = "/net/reactivated/Fprint/Manager"
DEVICE_PATH = "/net/reactivated/Fprint/Device/0"

HW_NAME = "com.huawei.Fingerprint"
HW_PATH = "/com/huawei/Fingerprint"
HW_IFACE = "com.huawei.Fingerprint"

STATE_DIR = "/var/lib/l410-fprint"
STATE_FILE = os.path.join(STATE_DIR, "enrolled.json")
LOG_FILE = "/var/log/fp_kirin/fp_hal.log"
IRQ_NODE = "/sys/bus/platform/devices/fingerprint/irq"

# The TA advances "p" by 8 % per accepted image (13 images -> 100 %).
PERCENT_PER_STAGE = 8
NUM_ENROLL_STAGES = 100 // PERCENT_PER_STAGE

MANAGER_XML = """
<node>
  <interface name="net.reactivated.Fprint.Manager">
    <method name="GetDevices">
      <arg type="ao" name="devices" direction="out"/>
    </method>
    <method name="GetDefaultDevice">
      <arg type="o" name="device" direction="out"/>
    </method>
  </interface>
</node>
"""

DEVICE_XML = """
<node>
  <interface name="net.reactivated.Fprint.Device">
    <method name="ListEnrolledFingers">
      <arg type="s" name="username" direction="in"/>
      <arg type="as" name="enrolled_fingers" direction="out"/>
    </method>
    <method name="DeleteEnrolledFingers">
      <arg type="s" name="username" direction="in"/>
    </method>
    <method name="DeleteEnrolledFingers2"/>
    <method name="DeleteEnrolledFinger">
      <arg type="s" name="finger_name" direction="in"/>
    </method>
    <method name="Claim">
      <arg type="s" name="username" direction="in"/>
    </method>
    <method name="Release"/>
    <method name="VerifyStart">
      <arg type="s" name="finger_name" direction="in"/>
    </method>
    <method name="VerifyStop"/>
    <method name="EnrollStart">
      <arg type="s" name="finger_name" direction="in"/>
    </method>
    <method name="EnrollStop"/>
    <signal name="VerifyFingerSelected">
      <arg type="s" name="finger_name"/>
    </signal>
    <signal name="VerifyStatus">
      <arg type="s" name="result"/>
      <arg type="b" name="done"/>
    </signal>
    <signal name="EnrollStatus">
      <arg type="s" name="result"/>
      <arg type="b" name="done"/>
    </signal>
    <property name="name" type="s" access="read"/>
    <property name="num-enroll-stages" type="i" access="read"/>
    <property name="scan-type" type="s" access="read"/>
    <property name="finger-present" type="b" access="read"/>
    <property name="finger-needed" type="b" access="read"/>
  </interface>
</node>
"""

ERROR_PREFIX = "net.reactivated.Fprint.Error."


class FprintError(Exception):
    def __init__(self, name, message):
        super().__init__(message)
        self.dbus_name = ERROR_PREFIX + name
        self.message = message


def log(msg):
    print(msg, flush=True)


class State:
    """Claim state plus enrolled-print bookkeeping (fprintd has no storage)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.claimed_by = None      # username
        self.action = None          # None | "enroll" | "verify"
        self.cancel = threading.Event()
        self.worker = None
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        self.enrolled = {}
        try:
            with open(STATE_FILE) as f:
                self.enrolled = json.load(f)
        except (OSError, ValueError):
            self.enrolled = {}

    def save(self):
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.enrolled, f, indent=1, sort_keys=True)
        os.replace(tmp, STATE_FILE)
        os.chmod(STATE_FILE, 0o600)

    def fingers(self, user):
        return list(self.enrolled.get(user, []))

    def add(self, user, finger):
        with self.lock:
            cur = set(self.enrolled.get(user, []))
            cur.add(finger)
            self.enrolled[user] = sorted(cur)
            self.save()

    def remove(self, user, finger=None):
        with self.lock:
            if finger is None:
                removed = self.enrolled.pop(user, [])
            else:
                cur = set(self.enrolled.get(user, []))
                removed = [finger] if finger in cur else []
                cur.discard(finger)
                if cur:
                    self.enrolled[user] = sorted(cur)
                else:
                    self.enrolled.pop(user, None)
            self.save()
            return removed


STATE = State()


def hw_call(conn, method, args=None, reply="(i)", timeout=60000):
    """Call the Huawei daemon synchronously."""
    rt = GLib.VariantType.new(reply) if reply else None
    return conn.call_sync(
        HW_NAME, HW_PATH, HW_IFACE, method, args, rt,
        Gio.DBusCallFlags.NONE, timeout, None)


def hw_int(conn, method, args=None, timeout=60000):
    res = hw_call(conn, method, args, "(i)", timeout)
    return res.unpack()[0]


def finger_present():
    try:
        with open(IRQ_NODE) as f:
            return f.read().strip() != "0"
    except OSError:
        return False


def progress_watcher(cancel, on_stage):
    """Follow the daemon's log so fprintd clients see real enroll stages."""
    try:
        with open(LOG_FILE, "rb") as f:
            f.seek(0, os.SEEK_END)
            buf = b""
            while not cancel.is_set():
                chunk = f.read()
                if not chunk:
                    time.sleep(0.2)
                    continue
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    m = re.search(rb"Enrol took \d+ ms \(p: (\d+)", line)
                    if m:
                        on_stage(int(m.group(1)))
    except OSError:
        return


class Manager:
    def __init__(self, conn):
        self.conn = conn

    def handle(self, method, params, invocation):
        log("manager call %s" % method)
        if method == "GetDevices":
            invocation.return_value(GLib.Variant("(ao)", ([DEVICE_PATH],)))
        elif method == "GetDefaultDevice":
            invocation.return_value(GLib.Variant("(o)", (DEVICE_PATH,)))
        else:
            invocation.return_dbus_error(ERROR_PREFIX + "Internal",
                                         "unknown method " + method)


class Device:
    def __init__(self, conn):
        self.conn = conn
        self.state = STATE

    # ---- helpers -------------------------------------------------------
    def _caller_user(self, invocation):
        try:
            res = invocation.get_connection().call_sync(
                "org.freedesktop.DBus", "/org/freedesktop/DBus",
                "org.freedesktop.DBus", "GetConnectionUnixUser",
                GLib.Variant("(s)", (invocation.get_sender(),)),
                GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NONE, 5000, None)
            uid = res.unpack()[0]
            return pwd.getpwuid(uid).pw_name
        except GLib.Error:
            return None

    def _resolve_user(self, invocation, username):
        if username:
            return username
        return self._caller_user(invocation)

    def _emit(self, signal, signature, value):
        self.conn.emit_signal(None, DEVICE_PATH,
                              "net.reactivated.Fprint.Device", signal,
                              GLib.Variant(signature, value))

    def _require_claim(self, invocation):
        if not self.state.claimed_by:
            raise FprintError("ClaimDevice", "Device not claimed")

    def _require_idle(self, invocation):
        if self.state.action:
            raise FprintError("AlreadyInUse", "Device already in use")

    # ---- methods -------------------------------------------------------
    def handle(self, method, params, invocation):
        try:
            return self._handle(method, params, invocation)
        except FprintError as e:
            invocation.return_dbus_error(e.dbus_name, e.message)
        except GLib.Error as e:
            invocation.return_dbus_error(ERROR_PREFIX + "Internal", str(e))
        except Exception as e:                      # noqa: BLE001
            invocation.return_dbus_error(ERROR_PREFIX + "Internal", repr(e))

    def _handle(self, method, params, invocation):
        log("device call %s%s from %s" % (
            method,
            params.print_(True) if params is not None else "",
            self._caller_user(invocation)))
        if method == "Claim":
            (username,) = params.unpack()
            user = self._resolve_user(invocation, username)
            if not user:
                raise FprintError("PermissionDenied", "cannot resolve caller")
            if self.state.claimed_by:
                raise FprintError("AlreadyInUse", "Device already claimed")
            self.state.claimed_by = user
            # Wake the vendor stack: session + device check.
            try:
                hw_int(self.conn, "StartSession", None, 60000)
                hw_call(self.conn, "SearchDevice", None, "(b)", 30000)
            except GLib.Error as e:
                self.state.claimed_by = None
                raise FprintError("Internal", "huawei daemon: %s" % e.message)
            log("claimed by %s" % user)
            invocation.return_value(None)
            return

        if method == "Release":
            if not self.state.claimed_by:
                raise FprintError("ClaimDevice", "Device not claimed")
            if self.state.action:
                self._stop_action()
            try:
                hw_int(self.conn, "Close", None, 15000)
            except GLib.Error:
                pass
            log("released (%s)" % self.state.claimed_by)
            self.state.claimed_by = None
            invocation.return_value(None)
            return

        if method == "ListEnrolledFingers":
            (username,) = params.unpack()
            user = self._resolve_user(invocation, username)
            fingers = self.state.fingers(user)
            if not fingers:
                raise FprintError("NoEnrolledPrints",
                                  "no enrolled prints for %s" % user)
            invocation.return_value(GLib.Variant("(as)", (fingers,)))
            return

        if method in ("DeleteEnrolledFingers", "DeleteEnrolledFingers2",
                      "DeleteEnrolledFinger"):
            user = self._resolve_user(invocation, "")
            finger = params.unpack()[0] if params.n_children() else None
            removed = self.state.remove(user, finger)
            if not removed:
                raise FprintError("NoEnrolledPrints", "nothing to delete")
            # The template itself lives in the TA's SFS; the vendor daemon
            # exposes no delete call, so only our bookkeeping is updated.
            log("forgot %s for %s (template stays in the TEE)" % (removed, user))
            invocation.return_value(None)
            return

        if method == "EnrollStart":
            (finger,) = params.unpack()
            self._require_claim(invocation)
            self._require_idle(invocation)
            if finger == "any":
                raise FprintError("InvalidFingername", "any is not valid here")
            if finger in self.state.fingers(self.state.claimed_by):
                raise FprintError("FingerAlreadyEnrolled",
                                  "%s already enrolled" % finger)
            self._start_enroll(finger)
            invocation.return_value(None)
            return

        if method == "EnrollStop":
            if self.state.action != "enroll":
                raise FprintError("NoActionInProgress", "no enroll in progress")
            self._stop_action()
            invocation.return_value(None)
            return

        if method == "VerifyStart":
            (finger,) = params.unpack()
            self._require_claim(invocation)
            self._require_idle(invocation)
            if not self.state.fingers(self.state.claimed_by):
                raise FprintError("NoEnrolledPrints", "nothing enrolled")
            self._start_verify(finger)
            invocation.return_value(None)
            return

        if method == "VerifyStop":
            if self.state.action != "verify":
                raise FprintError("NoActionInProgress", "no verify in progress")
            self._stop_action()
            invocation.return_value(None)
            return

        raise FprintError("Internal", "unknown method " + method)

    # ---- enroll --------------------------------------------------------
    def _start_enroll(self, finger):
        user = self.state.claimed_by
        self.state.action = "enroll"
        self.state.cancel.clear()
        self.state.worker = threading.Thread(
            target=self._enroll_worker, args=(user, finger), daemon=True)
        self.state.worker.start()

    def _enroll_worker(self, user, finger):
        last_stage = [0]

        def on_stage(percent):
            stage = min(NUM_ENROLL_STAGES, max(1, percent // PERCENT_PER_STAGE))
            while last_stage[0] < stage:
                last_stage[0] += 1
                if self.state.cancel.is_set():
                    return
                self._emit("EnrollStatus", "(sb)",
                           ("enroll-stage-passed", False))

        watcher = threading.Thread(
            target=progress_watcher,
            args=(self.state.cancel, on_stage), daemon=True)
        watcher.start()

        db_path = os.path.join(STATE_DIR, "template-%s" % user)
        result = -1
        try:
            result = hw_int(self.conn, "Enroll",
                            GLib.Variant("(ss)", (db_path, user)),
                            30 * 60 * 1000)
        except GLib.Error as e:
            log("Enroll failed: %s" % e.message)
        # Read the stop flag before we set it ourselves: setting it here only
        # stops the log watcher, it must not turn a successful enrollment into
        # a "cancelled" one (that bug kept KDE waiting forever).
        cancelled = self.state.cancel.is_set()
        self.state.cancel.set()

        if cancelled:
            log("enroll cancelled (result=%d)" % result)
        elif result == 0:
            self.state.add(user, finger)
            log("enrolled %s for %s" % (finger, user))
            self._emit("EnrollStatus", "(sb)", ("enroll-completed", True))
        else:
            log("enroll failed (result=%d)" % result)
            self._emit("EnrollStatus", "(sb)", ("enroll-failed", True))
        # Keep state.action until EnrollStop/Release: fprintd clients call
        # *Stop right after the final status and expect it to succeed.

    # ---- verify --------------------------------------------------------
    def _start_verify(self, finger):
        self.state.action = "verify"
        self.state.cancel.clear()
        self._emit("VerifyFingerSelected", "(s)", (finger,))
        self.state.worker = threading.Thread(
            target=self._verify_worker, args=(finger,), daemon=True)
        self.state.worker.start()

    def _verify_worker(self, finger):
        user = self.state.claimed_by
        result = -1
        try:
            # Identify blocks inside the TA until a finger is placed; the
            # daemon's own session timeout bounds it.
            result = hw_int(self.conn, "Identify",
                            GLib.Variant("(s)", (user,)),
                            10 * 60 * 1000)
        except GLib.Error as e:
            log("Identify failed: %s" % e.message)
        if self.state.cancel.is_set():
            log("verify cancelled")
            return
        log("identify result=%d (%s)" % (result, finger))
        if result == 0:
            self._emit("VerifyStatus", "(sb)", ("verify-match", True))
        else:
            self._emit("VerifyStatus", "(sb)", ("verify-no-match", True))
        # state.action stays set until VerifyStop, see _enroll_worker.

    def _stop_action(self):
        self.state.cancel.set()
        self.state.action = None
        worker = self.state.worker
        if worker is not None and worker.is_alive():
            # The TA's Identify blocks until a finger arrives; only Close()
            # makes the daemon cancel its worker thread, otherwise the daemon
            # stays "busy" and the next attempt fails.  Claim() re-opens the
            # session, so it is safe to drop it here.
            threading.Thread(target=self._abort_session, daemon=True).start()

    def _abort_session(self):
        try:
            hw_int(self.conn, "Close", None, 10000)
            log("session closed to abort the running action")
        except GLib.Error as e:
            log("Close failed: %s" % e.message)

    # ---- properties ----------------------------------------------------
    def properties(self):
        return {
            "name": GLib.Variant("s", "Huawei L410 power-button sensor (iTrustee TA)"),
            "num-enroll-stages": GLib.Variant("i", NUM_ENROLL_STAGES),
            "scan-type": GLib.Variant("s", "press"),
            "finger-present": GLib.Variant("b", finger_present()),
            "finger-needed": GLib.Variant("b", bool(self.state.action)),
        }


def props_handler(device, conn, sender, path, iface, method, params, invocation):
    props = device.properties()
    if method == "Get":
        name = params.unpack()[0]
        if name not in props:
            invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.InvalidArgs", name)
            return
        invocation.return_value(GLib.Variant("(v)", (props[name],)))
    elif method == "GetAll":
        invocation.return_value(
            GLib.Variant("(a{sv})", ({k: v for k, v in props.items()},)))
    elif method == "Set":
        invocation.return_dbus_error(
            "org.freedesktop.DBus.Error.PropertyReadOnly", "read-only")
    else:
        invocation.return_dbus_error(
            "org.freedesktop.DBus.Error.UnknownMethod", method)


def on_name_lost(conn, name):
    log("lost name %s, exiting" % name)
    os._exit(1)


def main():
    conn = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    manager_info = Gio.DBusNodeInfo.new_for_xml(MANAGER_XML)
    device_info = Gio.DBusNodeInfo.new_for_xml(DEVICE_XML)
    props_info = Gio.DBusNodeInfo.new_for_xml(
        "<node><interface name='org.freedesktop.DBus.Properties'>"
        "<method name='Get'><arg type='s' direction='in'/>"
        "<arg type='s' direction='in'/><arg type='v' direction='out'/></method>"
        "<method name='GetAll'><arg type='s' direction='in'/>"
        "<arg type='a{sv}' direction='out'/></method>"
        "<method name='Set'><arg type='s' direction='in'/>"
        "<arg type='s' direction='in'/><arg type='v' direction='in'/></method>"
        "</interface></node>").interfaces[0]

    manager = Manager(conn)
    device = Device(conn)

    # Gio hands method_call_closure (connection, sender, object_path,
    # interface_name, method_name, parameters, invocation); drop the four we
    # do not need.
    conn.register_object(
        MANAGER_PATH, manager_info.interfaces[0],
        lambda c, s, p, iface, m, prm, inv: manager.handle(m, prm, inv),
        None, None)
    conn.register_object(
        DEVICE_PATH, device_info.interfaces[0],
        lambda c, s, p, iface, m, prm, inv: device.handle(m, prm, inv),
        None, None)
    conn.register_object(DEVICE_PATH, props_info,
                         lambda c, s, p, i, m, pr, inv:
                         props_handler(device, c, s, p, i, m, pr, inv),
                         None, None)

    Gio.bus_own_name_on_connection(
        conn, BUS_NAME, Gio.BusNameOwnerFlags.NONE, None, on_name_lost)
    log("l410-fprintd-shim up on %s (%s)" % (BUS_NAME, DEVICE_PATH))
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
