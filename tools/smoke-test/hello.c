// hello.c
#include <pspkernel.h>
#include <pspdebug.h>

PSP_MODULE_INFO("hello", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(THREAD_ATTR_USER);

int main(void) {
    pspDebugScreenInit();
    pspDebugScreenPrintf("Hello from a Windows-built PSP binary.\n");
    sceKernelSleepThread();
    return 0;
}
