#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <AudioToolbox/AudioToolbox.h>
typedef struct AudioRing AudioRing;
AudioRing *ring_create(uint32_t capacity);
void ring_destroy(AudioRing *r);
uint32_t ring_write(AudioRing *r,const AudioBufferList *input);
uint32_t ring_read(AudioRing *r,uint32_t frames,AudioBufferList *output);
uint32_t ring_available(const AudioRing *r);
uint64_t ring_overflows(const AudioRing *r);
uint64_t ring_underruns(const AudioRing *r);
