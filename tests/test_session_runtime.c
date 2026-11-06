#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdint.h>
uint32_t meshkvm_session_abi(void);
void *meshkvm_session_open_ex(char *,size_t);
int meshkvm_session_poll(void *,char *,size_t);
void meshkvm_session_close(void *);
int main(void) {
    char error[512],identity[256];
    assert(meshkvm_session_abi()==0x00090001);
    void *h=meshkvm_session_open_ex(error,sizeof(error));
    if(!h) { printf("NOTE: native code linked; system runtime unavailable: %s\n",error); return 0; }
    int state=meshkvm_session_poll(h,identity,sizeof(identity));
    assert(state>=0 && state<=4);
    printf("PASS: native static guard open/poll/close with system runtime; state=%d\n",state);
    meshkvm_session_close(h);
    return 0;
}
