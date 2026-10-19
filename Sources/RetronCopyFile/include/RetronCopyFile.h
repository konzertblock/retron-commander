#ifndef RETRON_COPY_FILE_H
#define RETRON_COPY_FILE_H

#include <stdint.h>

typedef int32_t (*RetronCopyProgress)(int64_t copied_bytes, const char *source_path, void *context);

int32_t retron_copy_file(const char *source_path, const char *destination_path, int32_t move_source,
                             int32_t preserve_permissions, int32_t preserve_extended_attributes,
                             RetronCopyProgress progress, void *context);

#endif
