// Minimal fixture source module for test-audit-static's --src (best-effort
// "does this property name appear anywhere in the source under test" grep).
// Deliberately neutral/invented content.

function buildResult() {
  return { groupId: 'group-a' };
}

module.exports = { buildResult };
