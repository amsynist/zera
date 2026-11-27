package com.androp.approvals

import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject

internal const val WATCH_CAPABILITY = "zerax_approval_watch"
internal const val WATCH_REQUEST = "/zerax/approval/request"
internal const val WATCH_STATE = "/zerax/approval/state"

internal data class Approval(
    val id: String, val tool: String, val project: String, val details: String,
    val watchSummary: String, val watchActionable: Boolean
) {
    companion object {
        fun parse(json: JSONObject) = Approval(json.getString("id"), json.getString("tool"), json.getString("project"),
            json.getString("details"), json.getString("watchSummary"), json.getBoolean("watchActionable"))
    }
    fun forWatch() = JSONObject().put("id", id).put("project", project)
        .put("summary", watchSummary).put("actionable", watchActionable)
}

internal data class ApprovalState(
    val running: Boolean = false, val connected: Boolean = false,
    val status: String = "Pair with Zera on your Mac", val approvals: List<Approval> = emptyList(),
    val awaiting: String? = null, val watchName: String? = null
)

internal object Approvals {
    val state = MutableStateFlow(ApprovalState())
    var pairing: ApprovalPairing? = null
    var service: ApprovalService? = null
    @Volatile var watchId: String? = null
    var watchName: String? = null
}
