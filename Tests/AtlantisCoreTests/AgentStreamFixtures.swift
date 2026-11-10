import Foundation

/// Made-up `claude -p --output-format stream-json --verbose --include-partial-messages` lines, in the
/// shape the CLI prints (system/init, stream_event deltas, assistant blocks, user tool results, result).
enum StreamFixtures {
    static func initLine(tools: [String] = ["mcp__atlantis__atlantis_today", "mcp__atlantis__atlantis_school_timetable"],
                         servers: [String] = ["atlantis"]) -> String {
        let toolList = tools.map { "\"\($0)\"" }.joined(separator: ",")
        let serverList = servers.map { "{\"name\":\"\($0)\",\"status\":\"connected\"}" }.joined(separator: ",")
        return #"{"type":"system","subtype":"init","cwd":"/tmp/work","session_id":"s1","tools":["# + toolList
            + #"],"mcp_servers":["# + serverList + #"],"model":"claude-haiku","permissionMode":"dontAsk","slash_commands":[]}"#
    }

    static let hook = #"{"type":"system","subtype":"hook_started","hook_id":"h1","hook_name":"SessionStart:startup","session_id":"s1"}"#

    static func delta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"# + json(text) + #"}},"session_id":"s1","parent_tool_use_id":null}"#
    }

    static func assistantText(_ text: String, message: String = "msg_1") -> String {
        #"{"type":"assistant","message":{"id":""# + message + #"","type":"message","role":"assistant","model":"claude-haiku","content":[{"type":"text","text":"# + json(text) + #"}],"usage":{"input_tokens":1200,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":3000}},"parent_tool_use_id":null,"session_id":"s1"}"#
    }

    static func toolUse(_ id: String, _ name: String = "mcp__atlantis__atlantis_today", message: String = "msg_t") -> String {
        #"{"type":"assistant","message":{"id":""# + message + #"","type":"message","role":"assistant","model":"claude-haiku","content":[{"type":"tool_use","id":""# + id + #"","name":""# + name + #"","input":{}}],"usage":{"input_tokens":1000,"output_tokens":40}},"parent_tool_use_id":null,"session_id":"s1"}"#
    }

    static func toolResult(_ id: String, isError: Bool = false) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":""# + id + #"","type":"tool_result","content":[{"type":"text","text":"<atlantis_data source=\"atlantis_today\">ok</atlantis_data>"}],"is_error":"# + (isError ? "true" : "false") + #"}]},"parent_tool_use_id":null,"session_id":"s1"}"#
    }

    static func result(cost: Double = 0.0123, subtype: String = "success", isError: Bool = false, text: String = "Done.") -> String {
        #"{"type":"result","subtype":""# + subtype + #"","is_error":"# + (isError ? "true" : "false") + #","duration_ms":4321,"num_turns":3,"result":"# + json(text) + #","session_id":"s1","total_cost_usd":"# + String(cost) + #","usage":{"input_tokens":2200,"output_tokens":120}}"#
    }

    /// A normal run: one tool call, streamed text, a final answer and the cost.
    static var happyRun: [String] {
        [
            hook,
            initLine(),
            delta("Let me "), delta("check."),
            assistantText("Let me check.", message: "msg_1"),
            toolUse("toolu_1", "mcp__atlantis__atlantis_school_timetable", message: "msg_1"),
            toolResult("toolu_1"),
            delta("You have "), delta("**Maths** first."),
            assistantText("You have **Maths** first.", message: "msg_2"),
            result(cost: 0.0123, text: "You have **Maths** first."),
        ]
    }

    private static func json(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(decoding: data, as: UTF8.self)
    }
}
