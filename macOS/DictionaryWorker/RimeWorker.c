#include "RimeWorker.h"
#include <rime_api.h>
#include <string.h>
#include <stdatomic.h>

static RimeApi *initialize(const char *shared, const char *user, const char *cache) {
    RimeApi *api = rime_get_api();
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared;
    traits.user_data_dir = user;
    traits.staging_dir = cache;
    traits.prebuilt_data_dir = cache;
    traits.distribution_name = "InkFlow";
    traits.distribution_code_name = "inkflow-worker";
    traits.distribution_version = "1";
    traits.app_name = "rime.inkflow-worker";
    traits.min_log_level = 2;
    traits.log_dir = "";
    api->setup(&traits);
    api->initialize(&traits);
    return api;
}

static void deployment(void *context, RimeSessionId session, const char *type, const char *value) {
    (void)session;
    if (strcmp(type, "deploy")) return;
    atomic_int *status = context;
    if (!strcmp(value, "success")) atomic_store(status, 1);
    if (!strcmp(value, "failure")) atomic_store(status, -1);
}

int IFDictionaryCompile(const char *shared, const char *user, const char *cache) {
    RimeApi *api = initialize(shared, user, cache);
    atomic_int status = 0;
    api->set_notification_handler(deployment, &status);
    if (api->start_maintenance(1)) api->join_maintenance_thread();
    api->set_notification_handler(NULL, NULL);
    api->finalize();
    return atomic_load(&status) == 1 ? 0 : 1;
}

int IFDictionaryProbe(const char *shared, const char *user, const char *cache) {
    RimeApi *api = initialize(shared, user, cache);
    RimeSessionId session = api->create_session();
    int result = 0;
    if (!session || !api->select_schema(session, "inkflow_pinyin")) { result = 1; goto done; }
    const char *inputs[] = {"xiehouyu", "suranqijing", "email", "wofaleemail", "nihao"};
    const char *targets[] = {"歇后语", "肃然起敬", "email", "我发了email", "👋"};
    for (unsigned n = 0; n < sizeof(inputs) / sizeof(inputs[0]); ++n) {
        api->clear_composition(session);
        for (const char *key = inputs[n]; *key; ++key) api->process_key(session, *key, 0);
        RimeCandidateListIterator iterator = {0};
        int found = 0, count = 0;
        if (api->candidate_list_begin(session, &iterator)) {
            while (api->candidate_list_next(&iterator)) {
                ++count;
                if (!strcmp(iterator.candidate.text, targets[n])) { found = 1; break; }
                if ((n < 2 && count >= 1) || count >= 1000) break;
            }
            api->candidate_list_end(&iterator);
        }
        if (!found) { result = (int)n + 2; break; }
    }
done:
    if (session) { api->clear_composition(session); api->destroy_session(session); }
    api->finalize();
    return result;
}
