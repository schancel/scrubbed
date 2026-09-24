#define _POSIX_C_SOURCE 200809L

#include <nats/nats.h>

#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum {
    CONNECT_TIMEOUT_MS = 300,
    FETCH_TIMEOUT_MS = 200,
    CLOSE_TIMEOUT_MS = 2000,
    MAX_PAYLOAD_BYTES = 512,
    MAX_STREAM_MESSAGES = 4,
};

static const char *STREAM = "SCRUBBED_FRONTIER";
static const char *CONSUMER = "SCRUBBED_FRONTIER_V1";
static const char *SUBJECT = "scrubbed.frontier.v1";

typedef struct {
    atomic_int disconnected;
    atomic_int reconnected;
} ReconnectEvents;

static void disconnected(natsConnection *connection, void *closure);
static void reconnected(natsConnection *connection, void *closure);

static void fail(const char *what, natsStatus status, jsErrCode jetstream)
{
    fprintf(stderr, "jetstream probe: %s: %s (status=%d, jetstream=%u)\n",
            what, natsStatus_GetText(status), (int) status, (unsigned) jetstream);
    nats_PrintLastErrorStack(stderr);
    exit(2);
}

static void need(bool condition, const char *what)
{
    if (!condition) {
        fprintf(stderr, "jetstream probe: invariant failed: %s\n", what);
        exit(2);
    }
}

static void pause_ms(long milliseconds)
{
    struct timespec delay = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (milliseconds % 1000) * 1000000L,
    };
    while (nanosleep(&delay, &delay) != 0) {}
}

static natsOptions *options(const char *token, bool secure,
        ReconnectEvents *events)
{
    const char *url = getenv("NATS_URL");
    const char *ca = getenv("NATS_CA_FILE");
    natsOptions *opts = NULL;
    natsStatus status = natsOptions_Create(&opts);
    if (status != NATS_OK) fail("create options", status, 0);
    if ((status = natsOptions_SetURL(opts, url)) != NATS_OK ||
            (status = natsOptions_SetTimeout(opts, CONNECT_TIMEOUT_MS)) != NATS_OK ||
            (status = natsOptions_SetMaxReconnect(opts, 40)) != NATS_OK ||
            (status = natsOptions_SetReconnectWait(opts, 100)) != NATS_OK)
        fail("configure connection bounds", status, 0);
    if (token != NULL && (status = natsOptions_SetToken(opts, token)) != NATS_OK)
        fail("configure token", status, 0);
    if (secure) {
        if ((status = natsOptions_SetSecure(opts, true)) != NATS_OK ||
                (status = natsOptions_LoadCATrustedCertificates(opts, ca)) != NATS_OK)
            fail("configure TLS trust", status, 0);
    }
    if (events != NULL) {
        if ((status = natsOptions_SetDisconnectedCB(opts, disconnected, events)) != NATS_OK ||
                (status = natsOptions_SetReconnectedCB(opts, reconnected, events)) != NATS_OK)
            fail("configure reconnect callbacks", status, 0);
    }
    return opts;
}

static void disconnected(natsConnection *connection, void *closure)
{
    (void) connection;
    ReconnectEvents *events = closure;
    atomic_fetch_add(&events->disconnected, 1);
}

static void reconnected(natsConnection *connection, void *closure)
{
    (void) connection;
    ReconnectEvents *events = closure;
    atomic_fetch_add(&events->reconnected, 1);
}

static natsStatus connect_with(natsConnection **connection, const char *token,
        bool secure, ReconnectEvents *events)
{
    natsOptions *opts = options(token, secure, events);
    natsStatus status = natsConnection_Connect(connection, opts);
    natsOptions_Destroy(opts);
    return status;
}

static natsConnection *connect_trusted(ReconnectEvents *events)
{
    natsConnection *connection = NULL;
    const char *token = getenv("NATS_TOKEN");
    natsStatus status = connect_with(&connection, token, true, events);
    if (status != NATS_OK) fail("trusted TLS connection", status, 0);
    return connection;
}

static jsCtx *jetstream(natsConnection *connection)
{
    jsCtx *js = NULL;
    jsOptions opts;
    natsStatus status = jsOptions_Init(&opts);
    if (status != NATS_OK) fail("initialize JetStream options", status, 0);
    opts.Wait = 500;
    status = natsConnection_JetStream(&js, connection, &opts);
    if (status != NATS_OK) fail("create JetStream context", status, 0);
    return js;
}

static natsSubscription *bind(jsCtx *js)
{
    natsSubscription *subscription = NULL;
    jsSubOptions opts;
    jsErrCode error = 0;
    natsStatus status = jsSubOptions_Init(&opts);
    if (status != NATS_OK) fail("initialize subscription options", status, error);
    opts.Stream = STREAM;
    opts.Consumer = CONSUMER;
    status = js_PullSubscribe(&subscription, js, NULL, CONSUMER, NULL, &opts, &error);
    if (status != NATS_OK) fail("bind durable pull consumer", status, error);
    return subscription;
}

static natsMsg *fetch_one(natsSubscription *subscription, int64_t timeout,
        natsStatus *result)
{
    natsMsgList list = {0};
    jsErrCode error = 0;
    *result = natsSubscription_Fetch(&list, subscription, 1, timeout, &error);
    if (*result != NATS_OK) {
        natsMsgList_Destroy(&list);
        return NULL;
    }
    need(list.Count == 1, "bounded fetch returns exactly one message");
    natsMsg *message = list.Msgs[0];
    list.Msgs[0] = NULL;
    natsMsgList_Destroy(&list);
    return message;
}

static jsPubAck *publish(jsCtx *js, const char *payload, const char *id,
        natsStatus *result, jsErrCode *error)
{
    jsPubAck *ack = NULL;
    jsPubOptions opts;
    natsStatus status = jsPubOptions_Init(&opts);
    if (status != NATS_OK) fail("initialize publish options", status, 0);
    opts.MaxWait = 500;
    opts.MsgId = id;
    *result = js_Publish(&ack, js, SUBJECT, payload, (int) strlen(payload), &opts, error);
    return ack;
}

static void close_client(natsSubscription *subscription, jsCtx *js,
        natsConnection *connection)
{
    natsSubscription_Destroy(subscription);
    jsCtx_Destroy(js);
    natsConnection_Destroy(connection);
    natsStatus status = nats_CloseAndWait(CLOSE_TIMEOUT_MS);
    if (status != NATS_OK) fail("bounded client teardown", status, 0);
}

static void check_auth(void)
{
    natsConnection *connection = NULL;
    natsStatus plaintext = connect_with(&connection, NULL, false, NULL);
    natsConnection_Destroy(connection);
    need(plaintext != NATS_OK, "TLS-required server rejects plaintext client");

    natsStatus bad_token = connect_with(&connection, "deliberately-wrong", true, NULL);
    natsConnection_Destroy(connection);
    need(bad_token != NATS_OK, "server rejects an invalid token");

    connection = connect_trusted(NULL);
    natsConnection_Destroy(connection);
    natsStatus closed = nats_CloseAndWait(CLOSE_TIMEOUT_MS);
    if (closed != NATS_OK) fail("auth probe teardown", closed, 0);
    puts("auth\ttls-required=true\ttoken-rejected=true\ttrusted-token=true\tconnect-timeout-ms=300");
}

static void check_setup(void)
{
    natsConnection *connection = connect_trusted(NULL);
    jsCtx *js = jetstream(connection);
    jsErrCode error = 0;
    js_DeleteStream(js, STREAM, NULL, NULL);

    const char *subjects[] = {SUBJECT};
    jsStreamConfig stream;
    jsStreamInfo *stream_info = NULL;
    natsStatus status = jsStreamConfig_Init(&stream);
    if (status != NATS_OK) fail("initialize stream", status, error);
    stream.Name = STREAM;
    stream.Subjects = subjects;
    stream.SubjectsLen = 1;
    stream.Retention = js_WorkQueuePolicy;
    stream.MaxConsumers = 1;
    stream.MaxMsgs = MAX_STREAM_MESSAGES;
    stream.MaxBytes = 4096;
    stream.MaxMsgSize = MAX_PAYLOAD_BYTES;
    stream.Discard = js_DiscardNew;
    stream.Storage = js_FileStorage;
    stream.Replicas = 1;
    stream.Duplicates = 60LL * 1000 * 1000 * 1000;
    stream.PersistMode = js_PersistDefault;
    status = js_AddStream(&stream_info, js, &stream, NULL, &error);
    if (status != NATS_OK) fail("add bounded file stream", status, error);
    jsStreamInfo_Destroy(stream_info);

    jsConsumerConfig consumer;
    jsConsumerInfo *consumer_info = NULL;
    status = jsConsumerConfig_Init(&consumer);
    if (status != NATS_OK) fail("initialize consumer", status, error);
    consumer.Name = CONSUMER;
    consumer.Durable = CONSUMER;
    consumer.DeliverPolicy = js_DeliverAll;
    consumer.AckPolicy = js_AckExplicit;
    consumer.AckWait = 500LL * 1000 * 1000;
    consumer.MaxDeliver = 3;
    consumer.MaxAckPending = 1;
    consumer.MaxRequestBatch = 1;
    consumer.MaxRequestExpires = 1000LL * 1000 * 1000;
    status = js_AddConsumer(&consumer_info, js, STREAM, &consumer, NULL, &error);
    if (status != NATS_OK) fail("add bounded durable consumer", status, error);
    jsConsumerInfo_Destroy(consumer_info);

    jsPubAck *first = publish(js, "job-basic", "candidate-basic", &status, &error);
    if (status != NATS_OK) fail("publish admitted job", status, error);
    need(!first->Duplicate, "first candidate is admitted");
    uint64_t first_sequence = first->Sequence;
    jsPubAck_Destroy(first);
    jsPubAck *duplicate = publish(js, "job-basic", "candidate-basic", &status, &error);
    if (status != NATS_OK) fail("publish duplicate candidate", status, error);
    need(duplicate->Duplicate && duplicate->Sequence == first_sequence,
            "message id provides duplicate admission response");
    jsPubAck_Destroy(duplicate);

    char too_large[MAX_PAYLOAD_BYTES + 2];
    memset(too_large, 'x', sizeof(too_large) - 1);
    too_large[sizeof(too_large) - 1] = '\0';
    jsPubAck *oversized = publish(js, too_large, "candidate-oversized", &status, &error);
    jsPubAck_Destroy(oversized);
    need(status != NATS_OK, "server refuses payload above stream cap");

    natsSubscription *subscription = bind(js);
    natsMsg *message = fetch_one(subscription, 1000, &status);
    if (status != NATS_OK) fail("claim admitted job", status, error);
    jsMsgMetaData *metadata = NULL;
    status = natsMsg_GetMetaData(&metadata, message);
    if (status != NATS_OK) fail("read initial delivery metadata", status, error);
    need(metadata->NumDelivered == 1 && strcmp(metadata->Consumer, CONSUMER) == 0,
            "initial claim has durable identity and delivery generation one");
    jsMsgMetaData_Destroy(metadata);
    status = natsMsg_Nak(message, NULL);
    natsMsg_Destroy(message);
    if (status != NATS_OK) fail("nak claimed job", status, error);

    message = fetch_one(subscription, 1000, &status);
    if (status != NATS_OK) fail("fetch nak redelivery", status, error);
    status = natsMsg_GetMetaData(&metadata, message);
    if (status != NATS_OK) fail("read nak redelivery metadata", status, error);
    need(metadata->NumDelivered == 2, "nak increments delivery generation");
    jsMsgMetaData_Destroy(metadata);
    status = natsMsg_AckSync(message, NULL, &error);
    natsMsg_Destroy(message);
    if (status != NATS_OK) fail("ack redelivered job", status, error);

    message = fetch_one(subscription, FETCH_TIMEOUT_MS, &status);
    if (message != NULL) natsMsg_Destroy(message);
    need(status == NATS_TIMEOUT, "empty pull is time bounded");

    const char *payloads[] = {"bounded-1", "bounded-2", "bounded-3", "survive-restart"};
    const char *ids[] = {"candidate-1", "candidate-2", "candidate-3", "candidate-restart"};
    for (size_t i = 0; i < MAX_STREAM_MESSAGES; ++i) {
        jsPubAck *ack = publish(js, payloads[i], ids[i], &status, &error);
        if (status != NATS_OK) fail("fill bounded stream", status, error);
        jsPubAck_Destroy(ack);
    }
    jsPubAck *over_limit = publish(js, "bounded-5", "candidate-5", &status, &error);
    jsPubAck_Destroy(over_limit);
    need(status != NATS_OK, "discard-new refuses stream overflow");

    for (size_t i = 0; i < MAX_STREAM_MESSAGES; ++i) {
        message = fetch_one(subscription, 1000, &status);
        if (status != NATS_OK) fail("claim bounded stream item", status, error);
        need(strcmp(natsMsg_GetData(message), payloads[i]) == 0,
                "pull consumer preserves admitted order");
        if (i + 1 < MAX_STREAM_MESSAGES) {
            status = natsMsg_AckSync(message, NULL, &error);
            if (status != NATS_OK) fail("ack bounded stream item", status, error);
        }
        natsMsg_Destroy(message);
    }

    puts("setup\tadmit=true\tduplicate=true\tnak-redelivery=true\tack=true\tpayload-limit=512\tstream-limit=4\tinflight-limit=1\tpending-restart=true");
    close_client(subscription, js, connection);
}

static void check_restart(void)
{
    natsConnection *connection = connect_trusted(NULL);
    jsCtx *js = jetstream(connection);
    natsSubscription *subscription = bind(js);
    jsErrCode error = 0;
    natsStatus status;
    natsMsg *message = fetch_one(subscription, 1000, &status);
    if (status != NATS_OK) fail("claim persisted pending job", status, error);
    need(strcmp(natsMsg_GetData(message), "survive-restart") == 0,
            "pending content survives process restart");
    jsMsgMetaData *metadata = NULL;
    status = natsMsg_GetMetaData(&metadata, message);
    if (status != NATS_OK) fail("read restart redelivery metadata", status, error);
    need(metadata->NumDelivered >= 2 && strcmp(metadata->Consumer, CONSUMER) == 0,
            "durable consumer redelivers pending generation after restart");
    jsMsgMetaData_Destroy(metadata);
    status = natsMsg_AckSync(message, NULL, &error);
    natsMsg_Destroy(message);
    if (status != NATS_OK) fail("ack restart redelivery", status, error);

    message = fetch_one(subscription, FETCH_TIMEOUT_MS, &status);
    if (message != NULL) natsMsg_Destroy(message);
    need(status == NATS_TIMEOUT, "post-restart empty pull is time bounded");
    jsStreamInfo *stream_info = NULL;
    status = js_GetStreamInfo(&stream_info, js, STREAM, NULL, &error);
    if (status != NATS_OK) fail("inspect drained stream", status, error);
    need(stream_info->State.Msgs == 0, "work queue ack drains stored work");
    jsStreamInfo_Destroy(stream_info);

    puts("restart\tdurable-identity=true\tredelivery=true\tstate-survived=true\tfetch-timeout-ms=200\tdrained=true");
    close_client(subscription, js, connection);
}

static void check_reconnect(const char *marker)
{
    ReconnectEvents events = {0};
    natsConnection *connection = connect_trusted(&events);
    FILE *ready = fopen(marker, "w");
    need(ready != NULL, "create reconnect coordination marker");
    fputs("ready\n", ready);
    need(fclose(ready) == 0, "close reconnect coordination marker");

    for (int i = 0; i < 120; ++i) {
        if (atomic_load(&events.disconnected) > 0 &&
                atomic_load(&events.reconnected) > 0 &&
                natsConnection_Status(connection) == NATS_CONN_STATUS_CONNECTED)
            break;
        pause_ms(100);
    }
    need(atomic_load(&events.disconnected) > 0, "disconnect callback observed server stop");
    need(atomic_load(&events.reconnected) > 0, "reconnect callback observed server return");
    need(natsConnection_Status(connection) == NATS_CONN_STATUS_CONNECTED,
            "connection returned to connected state");

    jsCtx *js = jetstream(connection);
    jsErrCode error = 0;
    natsStatus status;
    jsPubAck *ack = publish(js, "after-reconnect", "candidate-reconnect", &status, &error);
    if (status != NATS_OK) fail("publish after automatic reconnect", status, error);
    jsPubAck_Destroy(ack);
    natsSubscription *subscription = bind(js);
    natsMsg *message = fetch_one(subscription, 1000, &status);
    if (status != NATS_OK) fail("claim after automatic reconnect", status, error);
    need(strcmp(natsMsg_GetData(message), "after-reconnect") == 0,
            "reconnected client reads its admitted job");
    status = natsMsg_AckSync(message, NULL, &error);
    natsMsg_Destroy(message);
    if (status != NATS_OK) fail("ack after automatic reconnect", status, error);

    puts("reconnect\tdisconnected=true\treconnected=true\tpublish-after-reconnect=true");
    close_client(subscription, js, connection);
}

static void delete_stream(void)
{
    natsConnection *connection = connect_trusted(NULL);
    jsCtx *js = jetstream(connection);
    jsErrCode error = 0;
    natsStatus status = js_DeleteStream(js, STREAM, NULL, &error);
    if (status != NATS_OK) fail("delete evaluation stream", status, error);
    close_client(NULL, js, connection);
}

int main(int argc, char **argv)
{
    const char *expected_version = getenv("NATS_C_EXPECTED_VERSION");
    need(expected_version != NULL, "NATS_C_EXPECTED_VERSION is required");
    need(strcmp(nats_GetVersion(), expected_version) == 0,
            "loaded nats.c version matches the pinned source");
    need(getenv("NATS_URL") != NULL, "NATS_URL is required");
    need(getenv("NATS_CA_FILE") != NULL, "NATS_CA_FILE is required");
    need(getenv("NATS_TOKEN") != NULL, "NATS_TOKEN is required");
    need(argc >= 2, "mode is required");
    if (strcmp(argv[1], "auth") == 0) check_auth();
    else if (strcmp(argv[1], "setup") == 0) check_setup();
    else if (strcmp(argv[1], "restart") == 0) check_restart();
    else if (strcmp(argv[1], "reconnect") == 0) {
        need(argc == 3, "reconnect marker path is required");
        check_reconnect(argv[2]);
    } else if (strcmp(argv[1], "delete") == 0) delete_stream();
    else need(false, "unknown mode");
    return 0;
}
