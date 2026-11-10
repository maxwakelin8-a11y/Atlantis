import Foundation

/// Registers every Atlantis tool from PRD §8.
public enum AtlantisTools {
    public static func register(in registry: ToolRegistry, context: MCPToolContext) {
        TaskTools.register(in: registry, context: context)
        InboxTools.register(in: registry, context: context)
        SchoolTools.register(in: registry, context: context)
        DocTools.register(in: registry, context: context)
        AgentTools.register(in: registry, handler: context.delegate)
    }

    /// The tool names, for tests and docs.
    public static let names = [
        "atlantis_today", "atlantis_tasks_list", "atlantis_task_add", "atlantis_task_update",
        "atlantis_inbox_post", "atlantis_inbox_list", "atlantis_seqta_refresh",
        "atlantis_school_timetable", "atlantis_school_assessments", "atlantis_school_subjects",
        "atlantis_school_notices", "atlantis_school_messages", "atlantis_message_draft",
        "atlantis_docs_list", "atlantis_docs_search", "atlantis_doc_read", "atlantis_doc_write", "atlantis_doc_export",
        AgentDelegation.toolName,
    ]
}
