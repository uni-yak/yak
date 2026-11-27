// System V 的拥有值运行时。堆分配与释放由本目标的汇编系统调用桥提供。
typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;

extern void *yak_rt_alloc(u64 size);
extern void yak_rt_free(u64 address, u64 size);

#include "../value_ops.inc"
