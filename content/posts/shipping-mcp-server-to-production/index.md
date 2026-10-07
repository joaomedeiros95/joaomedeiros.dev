+++
title = 'Shipping an MCP server to production in 10 days (and why auth was the hard part)'
date = 2026-10-07
summary = 'We shipped an MCP server in 10 days and onboarded 50+ customers in the first week. This post covers what the tutorials skip: OAuth in MCP, mapping tools to real production data, rate limiting, and why you have to guide the output format of the AI tools calling you.'
toc = true
draft = true
tags = ["MCP", "AI", "OAuth", "API", "Claude", "Production"]
showTags = true
+++

## Introduction
Most MCP tutorials focus on getting a server running and a first tool working. Very few cover what happens when real customers, with real data and real SSO policies, connect their agents to your server.

At [Warmly](https://www.warmly.ai) I built our [MCP server](https://www.warmly.ai/launches/warmly-mcp-and-api-are-live). We went from zero to production in 10 days, and in the first week more than 50 customers connected it to Claude Desktop, Claude Code, Cursor, ChatGPT, Codex and other MCP clients. Very few people have run MCP in production with paying customers yet, so I want to write down the parts that surprised me.

>TL;DR: Writing tools is the easy part. Authentication took most of the effort, tool design should follow the questions customers ask (not your database tables), rate limits need to be explained to the model and not only to humans, and if you don't tell the AI how to present your data, every response will look different.

## Auth was the hard part
### Why it's harder than a normal API
For our REST API, authentication is boring: the customer creates an API key and sends it as a bearer token. MCP clients don't work like that. A user adds a URL to Claude Desktop or runs a single command:

```shell
claude mcp add --transport http warmly https://opps-api.getwarmly.com/api/mcp
```

From there, the client is expected to discover how to authenticate on its own, open a browser, let the user log in, and come back with a token. Nobody pastes a key anywhere. That means your server needs to speak the [MCP authorization spec](https://modelcontextprotocol.io/specification/latest/basic/authorization), which is OAuth 2.1 with a few extra pieces most of us never had to implement:

- **Protected Resource Metadata ([RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728)):** when an unauthenticated request arrives, the server answers `401` with a `WWW-Authenticate` header pointing to a metadata document. That document tells the client which authorization server to use.
- **Authorization Server Metadata ([RFC 8414](https://datatracker.ietf.org/doc/html/rfc8414)):** the client then discovers the authorization, token and registration endpoints.
- **Client registration:** the client is not known in advance. Every Claude Desktop, Cursor or custom agent install is a new OAuth client, so you need [Dynamic Client Registration (RFC 7591)](https://datatracker.ietf.org/doc/html/rfc7591) or the newer Client ID Metadata Documents approach.
- **PKCE and resource indicators:** PKCE is mandatory, and tokens must be bound to your server ([RFC 8707](https://datatracker.ietf.org/doc/html/rfc8707)) so a token issued for another MCP server can't be replayed against yours.

Each piece is simple when you read it alone. The trouble is that every client implements the discovery flow a little differently, and when something is wrong the user usually sees a generic "failed to connect" message with no details.

### Plugging into the login we already had
Our customers already log in to Warmly through [WorkOS](https://workos.com), and we did not want a second set of credentials just for MCP. So instead of building our own OAuth server, we made WorkOS the authorization server for MCP clients too. It handles the discovery and client registration steps described above and issues the tokens.

That kept our side small. The MCP server is only a resource server: it points clients to WorkOS in its protected resource metadata and validates the tokens they send. SSO customers using Okta or Google Workspace were already handled by WorkOS, so their MCP login goes through the same flow without any SSO-specific code on our side.

After login, the token issued to the MCP client is tied to the user, and every tool call runs with exactly that user's permissions.

### Multi-org users
Some users belong to more than one Warmly organization. A token says *who* you are but not *which workspace* you are asking about.

For users with a single organization, there is nothing to decide: the server picks their organization automatically. For users with more than one, we chose not to guess. Assuming the wrong organization would mean answering with another workspace's data, which is dangerous. Instead, the client pins the organization, either in the URL or in a header:

```shell
# Claude Desktop: query parameter
https://opps-api.getwarmly.com/api/mcp?organization_id=<uuid>

# CLI clients: header
X-Warmly-Organization-Id: <uuid>
```

The server validates that the authenticated user belongs to that organization, so the parameter only selects among the workspaces the user can already access.

Pinning also has a nice side effect: users with several organizations can add one MCP server per organization they want to access, each one pinned to its own workspace.

### Lessons
> **TODO(joao):** add the concrete bugs you hit (redirect URI mismatches, token refresh, clients caching a broken registration, etc.).

- Test with every client you plan to support, not only the one you use. They don't behave the same way during discovery and token refresh.
- Log the whole OAuth handshake on the server side. The client will rarely tell the user what went wrong, so your logs are the only source of truth.
- Keep tokens short-lived and make refresh work early. A broken refresh shows up as "the MCP stopped working" a day after onboarding.

## Mapping tools to real data
The temptation when building an MCP server is to expose your API one endpoint per tool. Don't do that. A model is not a frontend developer: it doesn't want twenty small tools to combine, it wants a few tools that answer the questions a user actually asks.

We launched with a small, read-only set:

| Tool | Question it answers |
|------|---------------------|
| `list_warm_visitors` | Who from which companies visited my site recently, and what did they look at? |
| `list_warm_accounts` | Same data grouped by company, with sessions, identified visitors and distinct pages |
| `list_third_party_signals` | Which companies show a buying signal right now? Or, what signals fired on this domain? |
| `get_credits_remaining` | How many credits does my workspace still have this month? |

> **TODO(joao):** verify the internal detail/rationale in the paragraph below.

Behind `list_warm_accounts` there is no `accounts` table that maps one to one. It aggregates visitor sessions, identity resolution, company enrichment and CRM presence (HubSpot, Salesforce, Pipedrive) into a single row per company. That aggregation lives on the server, so the model receives one clean answer instead of trying to join three tools by itself.

> **TODO(joao):** verify the internal detail/rationale in the paragraph below.

`list_third_party_signals` has two modes, `by_signal` and `by_company`, because those are the two questions people ask: "who is hiring sales reps?" and "what's going on with acme.com?". One tool with a mode was clearer to the model than two tools with overlapping parameters.

A few things that made the tools work well in production:

- **Sensible defaults and hard limits.** `timeWindow` defaults to the past day and caps at a week, and `take` defaults to 25 with a maximum of 500. Without limits, the model will happily ask for everything.
- **A `preview` flag.** With `preview: true` the tool returns an estimated row count without spending credits, so the model can check the size of a query before running it.
- **Closed vocabularies have to be in the tool description.** Our signal taxonomy has hundreds of subtypes. Claude will invent plausible signal names that don't exist, so we either document the catalog or tell the model to fall back to the broader `signalCategory` and let the server fan out.

## Rate limiting
> **TODO(joao):** describe the implementation (where the limiter lives, keyed by user/org/token, storage).

Agents are much more aggressive than humans. A single prompt like "check all of these 40 domains" turns into 40 tool calls in a few seconds, and an agent running in a loop can do that all day.

The limits are 60 calls per minute on the free tier and 120 on paid plans. Going over returns `HTTP 429`, and it's safe to retry after about 60 seconds.

The part that matters for MCP is that the **model** reads the error, not a developer. A bare `429 Too Many Requests` often makes the agent give up or retry immediately. An error message that explains the limit and when to retry makes the agent wait or batch its work. Treat error messages as part of the prompt.

Rate limiting also connects to billing: calls are free, but new companies and contacts consume credits. That's a big topic on its own, so I'll cover it in a companion post about metering AI agents and charging credits per tool call.

## Expected vs. actual usage
> **TODO(joao):** fill in with real numbers from the first week(s): call share per tool, surprising prompts, client mix (Claude Desktop vs Claude Code vs Cursor vs ChatGPT vs Codex).

We expected customers to use the MCP the way they use our dashboard: open it in the morning, look at who visited yesterday, move on.

What actually happened:

- **TODO:** which tool got most of the calls, and how far that was from our guess.
- **TODO:** the most surprising use case (for example, people chaining our data with their CRM or email MCP in the same conversation).
- **TODO:** client mix and whether agents (scheduled/loops) or humans in chat drove most of the traffic.

The lesson for me was to instrument tool calls from day one: tool name, parameters, client, latency and result size. You can't guess how a model will use your tools; you can only measure it.

## Guide the output format
This one surprised me the most. We returned the same data for the same question, and every time the customer got a different table: different columns, different order, sometimes a list, sometimes a summary paragraph. For people sharing the output with their sales team, that inconsistency felt like a bug in our product, even though our data never changed.

The AI client decides how to render the result, but you can steer it heavily:

> **TODO(joao):** confirm the exact techniques used and add a real snippet of a tool description / response.

- **Put presentation guidance in the tool description.** Tell the model which fields matter, which ones to show as columns, and the order. Models follow tool descriptions surprisingly closely.
- **Return structured data with stable field names.** The same keys in the same order on every call give the model less room to improvise.
- **Drop noise from the response.** Every field you return is a field the model might decide to show. If it's not useful to the user, don't send it.
- **Include short hints in the response itself**, like "show these as a table with company, visitors and last visit". It costs a few tokens and pays back in consistency.

## Conclusion
Building an MCP server is easy. Running one in production is a different job: most of the work is authentication across many clients, designing tools around questions instead of tables, explaining limits and errors to a model, and steering how that model shows your data to the user.

If you're about to ship one, start with auth. The tools will take less time than you think, and the OAuth flow will take more.

Have you shipped an MCP server to real users yet? What was the hard part for you?
