// Neutral fixture for scripts/lib/test-audit-static.js — genuine assertions
// only; the scanner must produce zero findings across every rule for this
// file (paired with vacuous.test.js, which has one instance of each).

describe('clean fixture', () => {
  it('adds two numbers correctly', () => {
    const sum = 1 + 1;
    expect(sum).toBe(2);
  });

  it('builds a result object and asserts its real property', () => {
    const result = { groupId: 'group-a' };
    expect(result.groupId).toBe('group-a');
    expect(result.groupId).not.toBe('group-b');
  });
});
