/// A small HTTP/1.1 server on 127.0.0.1 for this package's streaming
/// fixtures. It is test scaffolding, not part of the library: it uses the
/// collector and exceptions freely.
///
/// Unlike the one-shot listeners in the older fixtures, it keeps a
/// connection open across requests (so connection reuse can be observed),
/// answers `Expect: 100-continue`, and gives the handler the request body
/// as a stream -- a handler can check a multi-gigabyte upload without the
/// server ever holding it. A handler can also drop or reset the connection
/// in the middle of a request, which is how the fixtures make a reused
/// connection fail under the client.
module loopback_server;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : to;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketShutdown, TcpSocket;
import std.string : indexOf, toLower;

/// One parsed request head. Header names are lowercased.
struct Request {
    string method;
    string target;          /// path and query, as sent
    string[string] headers;
    ulong contentLength;

    string header(string name) { auto p = name in headers; return p ? *p : null; }
}

/// Thrown by `Connection.drop`; unwinds the handler and closes the socket
/// without being recorded as a failure.
final class ConnectionDropped : Exception {
    this() { super("connection dropped on purpose"); }
}

/// One accepted connection, as a handler sees it.
final class Connection {
    /// 1 for the first connection the server accepted, 2 for the next, ...
    int id;
    private Socket peer;
    private ubyte[] buffered;   // bytes received beyond the request head
    private ulong bodyRemaining;

    private this(Socket peer, int id) { this.peer = peer; this.id = id; }

    /// Closes the connection now, whatever is still unread or unsent.
    void drop() { throw new ConnectionDropped; }

    /// Ends the connection after a response the handler has already sent,
    /// without first reading the rest of the request: closes the sending
    /// side, then discards what the client still sends until it lets go.
    /// This is a server that answers an upload early and hangs up.
    void closeAfterResponse() {
        peer.shutdown(SocketShutdown.SEND);
        ubyte[16 * 1024] discard;
        while (peer.receive(discard[]) > 0) {}
        throw new ConnectionDropped;
    }

    /// Fails the connection under a client that is in the middle of
    /// sending: stops reading for a moment, so the client's send stalls
    /// with most of its body still to go, then resets the connection
    /// without having answered a byte.
    void reset() {
        import core.time : msecs;
        import std.socket : Linger;
        Thread.sleep(300.msecs);
        Linger linger;
        linger.on = 1;
        linger.time = 0;
        peer.setOption(SocketOptionLevel.SOCKET, SocketOption.LINGER, linger);
        peer.close(); // with zero linger: a reset, not an orderly close
        throw new ConnectionDropped;
    }

    /// Reads up to `into.length` bytes of the current request's body.
    /// Returns 0 once the body is complete.
    size_t readBody(ubyte[] into) {
        if (bodyRemaining == 0 || into.length == 0) return 0;
        size_t want = into.length < bodyRemaining ? into.length : cast(size_t) bodyRemaining;
        size_t n;
        if (buffered.length) {
            n = buffered.length < want ? buffered.length : want;
            into[0 .. n] = buffered[0 .. n];
            buffered = buffered[n .. $];
        } else {
            auto got = peer.receive(into[0 .. want]);
            if (got <= 0) throw new Exception("client closed the connection mid-body");
            n = cast(size_t) got;
        }
        bodyRemaining -= n;
        return n;
    }

    void send(const(void)[] bytes) {
        while (bytes.length) {
            auto n = peer.send(bytes);
            if (n <= 0) throw new Exception("send failed");
            bytes = bytes[n .. $];
        }
    }

    /// Sends a status line, headers and an in-memory body.
    void respond(int status, string[string] headers, const(void)[] body_) {
        sendHead(status, headers, body_.length);
        send(body_);
    }

    /// Sends a status line and headers declaring `contentLength` bytes; the
    /// handler then streams that many with `send`.
    void sendHead(int status, string[string] headers, ulong contentLength) {
        auto head = "HTTP/1.1 " ~ status.to!string ~ " " ~ reason(status) ~ "\r\n";
        foreach (name, value; headers) head ~= name ~ ": " ~ value ~ "\r\n";
        head ~= "Content-Length: " ~ contentLength.to!string ~ "\r\n\r\n";
        send(head);
    }

    private static string reason(int status) {
        switch (status) {
            case 200: return "OK";
            case 204: return "No Content";
            case 206: return "Partial Content";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            default: return "Status";
        }
    }
}

alias Handler = void delegate(ref Request request, Connection connection);

final class LoopbackServer {
    ushort port;
    /// Whether `Expect: 100-continue` is answered. When it is not, the
    /// client sends its body after its own short wait, having received
    /// nothing at all -- the state in which a client may still decide a
    /// reused connection was dead and start over.
    bool answerExpect = true;
    private TcpSocket listener;
    private Thread acceptThread;
    private Thread[] connectionThreads;
    private Handler handler;
    private shared int accepted_;
    private shared bool stopping;
    private Mutex mutex;
    private string[] failures;

    this(Handler handler) {
        this.handler = handler;
        mutex = new Mutex;
        listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        port = (cast(InternetAddress) listener.localAddress()).port;
        listener.listen(16);
        acceptThread = new Thread(&acceptLoop);
        // Daemon threads: a fixture that fails must exit, not wait on a
        // blocked accept().
        acceptThread.isDaemon = true;
        acceptThread.start();
    }

    /// "http://127.0.0.1:<port>"
    string origin() { return "http://127.0.0.1:" ~ port.to!string; }

    /// How many TCP connections clients have opened so far.
    int connectionsAccepted() { return atomicLoad(accepted_); }

    /// Stops accepting, waits for open connections to finish, and returns
    /// anything a handler threw. Close the clients first.
    string[] stop() {
        atomicStore(stopping, true);
        // Wake the blocked accept().
        try {
            auto poke = new TcpSocket();
            poke.connect(new InternetAddress("127.0.0.1", port));
            poke.close();
        } catch (Exception) {}
        acceptThread.join();
        listener.close();
        foreach (t; connectionThreads) t.join();
        return failures;
    }

    private void fail(string message) {
        mutex.lock();
        scope(exit) mutex.unlock();
        failures ~= message;
    }

    private void acceptLoop() {
        while (true) {
            Socket peer;
            try peer = listener.accept();
            catch (Exception e) { if (!atomicLoad(stopping)) fail("accept: " ~ e.msg); return; }
            if (atomicLoad(stopping)) { peer.close(); return; }
            connectionThreads ~= serve(peer, atomicOp!"+="(accepted_, 1));
        }
    }

    // A function of its own so each thread closes over its own `peer`.
    private Thread serve(Socket peer, int id) {
        auto t = new Thread({
            scope(exit) if (peer.isAlive) { peer.shutdown(SocketShutdown.BOTH); peer.close(); }
            try serveConnection(new Connection(peer, id));
            catch (ConnectionDropped) {}
            catch (Exception e) fail(e.msg);
        });
        t.isDaemon = true;
        t.start();
        return t;
    }

    private void serveConnection(Connection conn) {
        ubyte[16 * 1024] chunk;
        while (true) {
            // Read one request head.
            ubyte[] head = conn.buffered;
            ptrdiff_t end;
            while ((end = (cast(const(char)[]) head).indexOf("\r\n\r\n")) < 0) {
                auto n = conn.peer.receive(chunk[]);
                if (n <= 0) {
                    if (head.length) throw new Exception("connection closed inside a request head");
                    return; // client closed between requests
                }
                head ~= chunk[0 .. cast(size_t) n];
            }
            conn.buffered = head[end + 4 .. $];

            auto request = parseHead(cast(string) head[0 .. end].idup);
            conn.bodyRemaining = request.contentLength;
            if (answerExpect && request.header("expect").toLower == "100-continue")
                conn.send("HTTP/1.1 100 Continue\r\n\r\n");

            handler(request, conn);

            // A handler that answered early may have left body unread.
            while (conn.readBody(chunk[])) {}
        }
    }

    private static Request parseHead(string head) {
        import std.array : split;
        import std.string : strip;

        auto lines = head.split("\r\n");
        auto parts = lines[0].split(" ");
        if (parts.length < 3) throw new Exception("malformed request line: " ~ lines[0]);
        Request request;
        request.method = parts[0];
        request.target = parts[1];
        foreach (line; lines[1 .. $]) {
            auto colon = line.indexOf(':');
            if (colon <= 0) throw new Exception("malformed header line: " ~ line);
            request.headers[line[0 .. colon].toLower] = line[colon + 1 .. $].strip;
        }
        if (auto length = "content-length" in request.headers) request.contentLength = (*length).to!ulong;
        return request;
    }
}
