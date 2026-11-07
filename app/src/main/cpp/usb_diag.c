#include <jni.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>

/* Same usbfs bulk ioctl used by Android's USB Host implementation, retaining errno.
 * Only operates on the already authorized UsbDeviceConnection file descriptor.
 * No device open, reset, control request or driver manipulation is performed here. */
JNIEXPORT jint JNICALL Java_hk_camlink_usb_NativeUsb_bulk(
        JNIEnv *env, jclass cls, jint fd, jint endpoint, jbyteArray bytes,
        jint length, jint timeout) {
    (void)cls;
    if (!bytes || length < 0 || length > 65536 || timeout < 1 || timeout > 30000 ||
        endpoint < 0 || endpoint > 255 || length > (*env)->GetArrayLength(env, bytes)) return -EINVAL;
    unsigned char buffer[65536];
    if (!(endpoint & 0x80)) {
        (*env)->GetByteArrayRegion(env, bytes, 0, length, (jbyte *)buffer);
        if ((*env)->ExceptionCheck(env)) return -EINVAL;
    }
    struct usbdevfs_bulktransfer transfer = {0};
    transfer.ep = (unsigned int)endpoint;
    transfer.len = (unsigned int)length;
    transfer.timeout = (unsigned int)timeout;
    transfer.data = buffer;
    int result = ioctl(fd, USBDEVFS_BULK, &transfer);
    int saved_errno = errno;
    if (result < 0) return -saved_errno;
    if (result > length) return -EOVERFLOW;
    if ((endpoint & 0x80) && result > 0) {
        (*env)->SetByteArrayRegion(env, bytes, 0, result, (const jbyte *)buffer);
    }
    return result;
}
