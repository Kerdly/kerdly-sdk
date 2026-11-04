package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyAttribution
import org.json.JSONObject

/** The public attribution object from a batch response or the attribution poll. */
internal object AttributionParser {
    /** Null unless the object carries at least `state` and `network`. */
    fun fromJson(o: JSONObject?): KerdlyAttribution? {
        if (o == null) return null
        val state = o.stringOrNull("state") ?: return null
        val network = o.stringOrNull("network") ?: return null
        return KerdlyAttribution(
            state = state,
            network = network,
            status = o.stringOrNull("status") ?: "",
            method = o.stringOrNull("method") ?: "",
            campaignId = o.stringOrNull("campaign_id"),
            campaign = o.stringOrNull("campaign"),
            adsetId = o.stringOrNull("adset_id"),
            adset = o.stringOrNull("adset"),
            adId = o.stringOrNull("ad_id"),
            ad = o.stringOrNull("ad"),
            keywordId = o.stringOrNull("keyword_id"),
            keyword = o.stringOrNull("keyword"),
            linkId = o.stringOrNull("link_id"),
            cppId = o.stringOrNull("cpp_id"),
            decidedAt = o.longOrNull("decided_at"),
            raw = o.toString(),
        )
    }

    /** `GET /v1/sdk/attribution`: `{"attribution": {…} | null, …}`, or the bare object. */
    fun fromPollBody(body: String): KerdlyAttribution? {
        val o = parseObject(body) ?: return null
        if (o.has("attribution")) return fromJson(o.optJSONObject("attribution"))
        return fromJson(o)
    }
}
