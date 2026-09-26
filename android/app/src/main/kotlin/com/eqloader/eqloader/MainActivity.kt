package com.eqloader.eqloader

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * USB HID bridge for the Dart side (lib/hid/android_usb_hid.dart).
 *
 * Methods on channel "eqloader/usb_hid":
 *   enumerate()                 -> list of HID interfaces of attached devices
 *   open(path)                  -> handle (asks for USB permission if needed)
 *   write(handle, data)         -> sends one output report (report id first)
 *   read(handle, timeoutMs)     -> next input report, or null on timeout
 *   close(handle)
 *
 * `path` is "<deviceName>#<interface index>". Like the kernel HID driver on
 * desktop, an open interface is polled continuously on a reader thread so no
 * input report is lost between read() calls.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "eqloader/usb_hid"
    private val actionUsbPermission = "com.eqloader.eqloader.USB_PERMISSION"

    private val usbManager by lazy { getSystemService(Context.USB_SERVICE) as UsbManager }
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    private val connections = HashMap<Int, HidConnection>()
    private var nextHandle = 1
    private val pendingPermissions = HashMap<String, MutableList<(Boolean) -> Unit>>()

    private class HidConnection(
        val connection: UsbDeviceConnection,
        val intf: UsbInterface,
        val inEp: UsbEndpoint?,
        val outEp: UsbEndpoint?,
    ) {
        val reports = LinkedBlockingQueue<ByteArray>()
        @Volatile var running = true
        var reader: Thread? = null

        fun startReader() {
            val ep = inEp ?: return
            reader = Thread {
                // One packet per transfer: a transfer that ends on a full
                // packet would otherwise wait for more data and time out,
                // losing it. A report longer than a packet arrives in pieces;
                // the protocol only reads its first packet.
                val buf = ByteArray(ep.maxPacketSize)
                while (running) {
                    val n = connection.bulkTransfer(ep, buf, buf.size, 100)
                    if (n > 0) reports.offer(buf.copyOf(n))
                }
            }.apply {
                isDaemon = true
                name = "usb-hid-reader"
                start()
            }
        }

        fun close() {
            running = false
            reader?.join(500)
            connection.releaseInterface(intf)
            connection.close()
        }
    }

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != actionUsbPermission) return
            val device: UsbDevice? = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }
            val name = device?.deviceName ?: return
            val granted = usbManager.hasPermission(device)
            pendingPermissions.remove(name)?.forEach { it(granted) }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val filter = IntentFilter(actionUsbPermission)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(permissionReceiver, filter)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler(::onMethodCall)
    }

    override fun onDestroy() {
        synchronized(connections) {
            connections.values.forEach { runCatching { it.close() } }
            connections.clear()
        }
        runCatching { unregisterReceiver(permissionReceiver) }
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "enumerate" -> result.success(enumerate())
            "open" -> open(call.argument<String>("path")!!, result)
            "write" -> background(result) {
                val conn = connection(call)
                val data = call.argument<ByteArray>("data")!!
                val n = if (conn.outEp != null) {
                    conn.connection.bulkTransfer(conn.outEp, data, data.size, 1000)
                } else {
                    // No interrupt-OUT endpoint: HID SET_REPORT (output) on EP0.
                    val reportId = data[0].toInt() and 0xFF
                    conn.connection.controlTransfer(
                        0x21, 0x09, (2 shl 8) or reportId, conn.intf.id,
                        data, data.size, 1000,
                    )
                }
                if (n < 0) throw IllegalStateException("USB write failed")
                null
            }
            "read" -> background(result) {
                val conn = connection(call)
                val timeout = (call.argument<Int>("timeoutMs") ?: 200).toLong()
                conn.reports.poll(timeout, TimeUnit.MILLISECONDS)
            }
            "close" -> background(result) {
                val handle = call.argument<Int>("handle")!!
                synchronized(connections) { connections.remove(handle) }?.close()
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun connection(call: MethodCall): HidConnection {
        val handle = call.argument<Int>("handle")!!
        return synchronized(connections) { connections[handle] }
            ?: throw IllegalStateException("USB device is not open")
    }

    /** Run [work] off the UI thread and deliver its value (or error) to [result]. */
    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        executor.execute {
            try {
                val value = work()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post { result.error("usb", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun enumerate(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        for (device in usbManager.deviceList.values) {
            for (i in 0 until device.interfaceCount) {
                val intf = device.getInterface(i)
                if (intf.interfaceClass != UsbConstants.USB_CLASS_HID) continue
                out.add(
                    mapOf(
                        "path" to "${device.deviceName}#$i",
                        "vendorId" to device.vendorId,
                        "productId" to device.productId,
                        "interfaceNumber" to intf.id,
                        "product" to runCatching { device.productName }.getOrNull(),
                        "manufacturer" to runCatching { device.manufacturerName }.getOrNull(),
                    )
                )
            }
        }
        return out
    }

    private fun open(path: String, result: MethodChannel.Result) {
        val deviceName = path.substringBeforeLast('#')
        val index = path.substringAfterLast('#').toIntOrNull() ?: 0
        val device = usbManager.deviceList[deviceName]
        if (device == null || index >= device.interfaceCount) {
            result.error("usb", "USB device is no longer attached; refresh the list", null)
            return
        }

        val proceed = { granted: Boolean ->
            if (!granted) {
                result.error("usb", "USB permission denied", null)
            } else {
                background(result) { openInterface(device, index) }
            }
        }
        if (usbManager.hasPermission(device)) {
            proceed(true)
            return
        }

        val waiting = pendingPermissions.getOrPut(deviceName) { mutableListOf() }
        waiting.add(proceed)
        if (waiting.size == 1) {
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val intent = Intent(actionUsbPermission).setPackage(packageName)
            usbManager.requestPermission(
                device, PendingIntent.getBroadcast(this, 0, intent, flags)
            )
        }
    }

    private fun openInterface(device: UsbDevice, index: Int): Int {
        val intf = device.getInterface(index)
        val connection = usbManager.openDevice(device)
            ?: throw IllegalStateException("Could not open USB device")
        if (!connection.claimInterface(intf, true)) {
            connection.close()
            throw IllegalStateException("Could not claim HID interface ${intf.id}")
        }

        var inEp: UsbEndpoint? = null
        var outEp: UsbEndpoint? = null
        for (e in 0 until intf.endpointCount) {
            val ep = intf.getEndpoint(e)
            if (ep.type != UsbConstants.USB_ENDPOINT_XFER_INT) continue
            if (ep.direction == UsbConstants.USB_DIR_IN) inEp = ep else outEp = ep
        }
        if (inEp == null) {
            connection.releaseInterface(intf)
            connection.close()
            throw IllegalStateException("HID interface ${intf.id} has no interrupt-IN endpoint")
        }

        val conn = HidConnection(connection, intf, inEp, outEp)
        conn.startReader()
        return synchronized(connections) {
            val handle = nextHandle++
            connections[handle] = conn
            handle
        }
    }
}
