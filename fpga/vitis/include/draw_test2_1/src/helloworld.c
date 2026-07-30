#include "hmi_measure_app.h"
#include "platform.h"
#include "xstatus.h"

int main(void)
{
    int status;

    init_platform();

    /*
     * UART1 is dedicated to the HMI.  Do not use print(), printf() or
     * xil_printf() in this application, otherwise their bytes will be sent
     * to the screen and may be interpreted as HMI commands.
     */
    status = HmiMeasureApp_Init();
    if (status != XST_SUCCESS)
        return status;

    for (;;)
        HmiMeasureApp_Service();
}
