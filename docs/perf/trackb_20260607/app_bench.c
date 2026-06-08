/* CPU-bound "application": spin counting for N seconds, print Mops/sec achieved.
 * When it shares a CPU with NIC softirq, achieved Mops/sec drops -> measures how
 * much CPU the application retains under NIC contention. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
int main(int argc, char **argv){
    double secs = argc>1 ? atof(argv[1]) : 10.0;
    struct timespec a,b; clock_gettime(CLOCK_MONOTONIC,&a);
    volatile unsigned long n=0; double el=0;
    do{ for(int i=0;i<1000000;i++) n++;
        clock_gettime(CLOCK_MONOTONIC,&b);
        el=(b.tv_sec-a.tv_sec)+(b.tv_nsec-a.tv_nsec)/1e9;
    } while(el<secs);
    printf("%.1f\n", (double)n/el/1e6);   /* Mops/sec */
    return 0;
}
