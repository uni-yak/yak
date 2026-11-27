// 动态数组追加：头为 u64[3] = {ptr, len, cap}，按 cap==0?4:cap*2 扩容。
// 返回 0 成功、1 内存不足；扩容失败保持原头不变（调用方映射为 AllocError）。
u64 yak_rt_push(u64 *header, const u8 *element, u64 element_size) {
    u64 len = header[1];
    u64 cap = header[2];
    if (len == cap) {
        u64 next = cap == 0 ? 4 : cap * 2;
        if (next < cap) {
            return 1;
        }
        if (element_size != 0 && next > 0xFFFFFFFFFFFFFFFFull / element_size) {
            return 1;
        }
        u64 bytes = next * element_size;
        u8 *buffer = (u8 *)yak_rt_alloc(bytes);
        if (buffer == 0) {
            return 1;
        }
        if (len != 0) {
            const u8 *old = (const u8 *)(unsigned long long)header[0];
            u64 copied = 0;
            u64 total = len * element_size;
            while (copied < total) {
                buffer[copied] = old[copied];
                copied = copied + 1;
            }
            yak_rt_free(header[0], cap * element_size);
        }
        header[0] = (u64)(unsigned long long)buffer;
        header[2] = next;
    }
    u8 *target = (u8 *)(unsigned long long)header[0] + len * element_size;
    u64 i = 0;
    while (i < element_size) {
        target[i] = element[i];
        i = i + 1;
    }
    header[1] = len + 1;
    return 0;
}

// 描述节点由目标发射器写入只读段。边的第二个字记录子节点向前的字数，
// 枚举的零距离表示该变体没有载荷。节点字段按四字节对齐。
enum { SHAPE_LEAF, SHAPE_RECORD, SHAPE_FIXED, SHAPE_DYNAMIC, SHAPE_ENUM };
enum { SHAPE_KIND, SHAPE_SIZE, SHAPE_TAG, SHAPE_COUNT, SHAPE_EDGES };

static u32 enum_tag(const u8 *address, const u32 *shape) {
    u32 tag = address[0];
    if (shape[SHAPE_TAG] == 2) {
        tag |= (u32)address[1] << 8;
    }
    return tag;
}

static void copy_value_bytes(u8 *dst, const u8 *src, u32 size) {
    for (u32 i = 0; i < size; ++i) {
        dst[i] = src[i];
    }
}

void yak_rt_drop_value(u8 *value, const u32 *shape) {
    const u32 *edges = shape + SHAPE_EDGES;
    switch (shape[SHAPE_KIND]) {
    case SHAPE_RECORD:
        for (u32 i = shape[SHAPE_COUNT]; i != 0; --i) {
            const u32 *edge = edges + 2ull * (i - 1);
            yak_rt_drop_value(value + edge[0], shape - edge[1]);
        }
        break;
    case SHAPE_FIXED:
    case SHAPE_DYNAMIC: {
        const u32 *child = shape - edges[1];
        u64 stride = child[SHAPE_SIZE];
        u8 *buffer = value;
        u64 count = shape[SHAPE_COUNT];
        int dynamic = shape[SHAPE_KIND] == SHAPE_DYNAMIC;
        u64 capacity = 0;
        if (dynamic) {
            const u64 *header = (const u64 *)value;
            buffer = (u8 *)header[0];
            count = header[1];
            capacity = header[2];
        }
        if (child[SHAPE_KIND] != SHAPE_LEAF) {
            while (count != 0) {
                --count;
                yak_rt_drop_value(buffer + count * stride, child);
            }
        }
        if (dynamic && buffer != 0) {
            yak_rt_free((u64)buffer, capacity * stride);
        }
        break;
    }
    case SHAPE_ENUM: {
        const u32 *edge = edges + 2ull * enum_tag(value, shape);
        if (edge[1] != 0) {
            yak_rt_drop_value(value + edge[0], shape - edge[1]);
        }
        break;
    }
    default:
        break;
    }
}

// 失败时只回滚已经完成的子值。数组头在全部元素成功后提交，
// 枚举在活跃载荷成功后才写标签。源一直保持存活。
u64 yak_rt_clone_value(const u8 *src, u8 *dst, const u32 *shape) {
    const u32 *edges = shape + SHAPE_EDGES;
    switch (shape[SHAPE_KIND]) {
    case SHAPE_RECORD:
        for (u32 i = 0; i < shape[SHAPE_COUNT]; ++i) {
            const u32 *edge = edges + 2ull * i;
            if (yak_rt_clone_value(src + edge[0], dst + edge[0], shape - edge[1])) {
                while (i != 0) {
                    --i;
                    edge -= 2;
                    yak_rt_drop_value(dst + edge[0], shape - edge[1]);
                }
                return 1;
            }
        }
        return 0;
    case SHAPE_FIXED:
    case SHAPE_DYNAMIC: {
        const u32 *child = shape - edges[1];
        u64 stride = child[SHAPE_SIZE];
        u64 count = shape[SHAPE_COUNT];
        const u8 *input = src;
        u8 *buffer = dst;
        int dynamic = shape[SHAPE_KIND] == SHAPE_DYNAMIC;
        if (dynamic) {
            const u64 *header = (const u64 *)src;
            count = header[1];
            input = (const u8 *)header[0];
            buffer = 0;
            if (count != 0) {
                if (count > 0xFFFFFFFFFFFFFFFFull / stride) {
                    return 1;
                }
                buffer = (u8 *)yak_rt_alloc(count * stride);
                if (buffer == 0) {
                    return 1;
                }
            }
        }
        for (u64 i = 0; i < count; ++i) {
            if (yak_rt_clone_value(input + i * stride, buffer + i * stride, child)) {
                while (i != 0) {
                    --i;
                    yak_rt_drop_value(buffer + i * stride, child);
                }
                if (dynamic) {
                    yak_rt_free((u64)buffer, count * stride);
                }
                return 1;
            }
        }
        if (dynamic) {
            u64 *header = (u64 *)dst;
            header[0] = (u64)buffer;
            header[1] = count;
            header[2] = count;
        }
        return 0;
    }
    case SHAPE_ENUM: {
        const u32 *edge = edges + 2ull * enum_tag(src, shape);
        if (edge[1] != 0 && yak_rt_clone_value(src + edge[0], dst + edge[0], shape - edge[1])) {
            return 1;
        }
        copy_value_bytes(dst, src, shape[SHAPE_TAG]);
        return 0;
    }
    default:
        copy_value_bytes(dst, src, shape[SHAPE_SIZE]);
        return 0;
    }
}
