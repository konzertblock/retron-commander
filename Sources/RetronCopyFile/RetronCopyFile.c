#include "RetronCopyFile.h"
#include <copyfile.h>
#include <sys/types.h>
#include <unistd.h>

struct RetronCallbackContext {
    RetronCopyProgress progress;
    void *context;
};

static int retron_copy_callback(int what, int stage, copyfile_state_t state,
                                    const char *source, const char *destination, void *context) {
    (void)destination;
    if (what != COPYFILE_COPY_DATA || stage != COPYFILE_PROGRESS) return COPYFILE_CONTINUE;

    off_t copied = 0;
    if (copyfile_state_get(state, COPYFILE_STATE_COPIED, &copied) != 0) return COPYFILE_QUIT;
    struct RetronCallbackContext *callback_context = (struct RetronCallbackContext *)context;
    if (!callback_context || !callback_context->progress) return COPYFILE_CONTINUE;
    return callback_context->progress((int64_t)copied, source, callback_context->context)
        ? COPYFILE_CONTINUE
        : COPYFILE_QUIT;
}

int32_t retron_copy_file(const char *source_path, const char *destination_path, int32_t move_source,
                             int32_t preserve_permissions, int32_t preserve_extended_attributes,
                             RetronCopyProgress progress, void *context) {
    copyfile_state_t state = copyfile_state_alloc();
    if (!state) return -1;

    struct RetronCallbackContext callback_context = { progress, context };
    copyfile_callback_t callback = retron_copy_callback;
    if (copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, (const void *)callback) != 0) {
        copyfile_state_free(state);
        return -1;
    }
    if (copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, &callback_context) != 0) {
        copyfile_state_free(state);
        return -1;
    }

    copyfile_flags_t flags = COPYFILE_DATA | COPYFILE_EXCL;
    if (preserve_permissions) flags |= COPYFILE_SECURITY;
    if (preserve_extended_attributes) flags |= COPYFILE_XATTR;
    int result = copyfile(source_path, destination_path, state, flags);
    copyfile_state_free(state);
    if (result != 0) return -1;
    if (move_source && unlink(source_path) != 0) return -1;
    return 0;
}
