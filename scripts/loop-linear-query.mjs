#!/usr/bin/env node
// Ad-hoc Linear query helper for the orchestrator tick.
// Usage: node scripts/loop-linear-query.mjs <mode> [json-args]
const TEAM_KEY = 'ABH';
const PROJECT_ID = '020087b9-2942-458d-98fa-85649bd8edc3';

async function linear(query, variables) {
  const key = process.env.LINEAR_API_KEY;
  if (!key) throw new Error('no LINEAR_API_KEY');
  const res = await fetch('https://api.linear.app/graphql', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: key },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`Linear ${res.status}: ${await res.text().catch(() => '')}`);
  const j = await res.json();
  if (j.errors) throw new Error(`Linear GQL: ${JSON.stringify(j.errors)}`);
  return j.data;
}

const mode = process.argv[2];
const arg = process.argv[3] ? JSON.parse(process.argv[3]) : {};

async function listBacklog() {
  // All open issues in the team+project (we'll filter untriaged client-side).
  const data = await linear(`{
    issues(first: 150, filter: {
      team: { key: { eq: "${TEAM_KEY}" } }
    }, orderBy: updatedAt) {
      nodes {
        id identifier title description createdAt updatedAt
        state { name type }
        project { id name }
        labels { nodes { id name } }
        assignee { id name }
      }
    }
  }`);
  return data.issues.nodes;
}

async function labels() {
  const data = await linear(`{
    team(id: "ABH") { id }
  }`).catch(() => null);
  // fetch label ids by name via issueLabels
  const d2 = await linear(`{
    issueLabels(first: 200) { nodes { id name } }
  }`);
  return d2.issueLabels.nodes;
}

async function addLabels() {
  // arg: { issueId, labelIds: [] }
  const data = await linear(
    `mutation($id: String!, $labelIds: [String!]) {
      issueUpdate(id: $id, input: { labelIds: $labelIds }) { success issue { identifier labels { nodes { name } } } }
    }`,
    { id: arg.issueId, labelIds: arg.labelIds }
  );
  return data;
}

async function setProject() {
  const data = await linear(
    `mutation($id: String!, $projectId: String!) {
      issueUpdate(id: $id, input: { projectId: $projectId }) { success issue { identifier project { name } } }
    }`,
    { id: arg.issueId, projectId: arg.projectId || PROJECT_ID }
  );
  return data;
}

async function comment() {
  const data = await linear(
    `mutation($id: String!, $body: String!) {
      commentCreate(input: { issueId: $id, body: $body }) { success }
    }`,
    { id: arg.issueId, body: arg.body }
  );
  return data;
}

async function createIssue() {
  const data = await linear(
    `mutation($input: IssueCreateInput!) {
      issueCreate(input: $input) { success issue { id identifier url } }
    }`,
    { input: arg }
  );
  return data;
}

async function setState() {
  const data = await linear(
    `mutation($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { identifier state { name } } }
    }`,
    { id: arg.issueId, stateId: arg.stateId }
  );
  return data;
}

async function states() {
  const d = await linear(`{
    workflowStates(first: 50, filter: { team: { key: { eq: "${TEAM_KEY}" } } }) {
      nodes { id name type }
    }
  }`);
  return d.workflowStates.nodes;
}

async function assign() {
  const data = await linear(
    `mutation($id: String!, $assigneeId: String!) {
      issueUpdate(id: $id, input: { assigneeId: $assigneeId }) { success issue { identifier assignee { name } } }
    }`,
    { id: arg.issueId, assigneeId: arg.assigneeId }
  );
  return data;
}

const fns = { listBacklog, labels, addLabels, setProject, comment, createIssue, setState, states, assign };
(async () => {
  const fn = fns[mode];
  if (!fn) { console.error('unknown mode', mode); process.exit(2); }
  const out = await fn();
  console.log(JSON.stringify(out, null, 2));
})().catch(e => { console.error(e.message); process.exit(1); });
