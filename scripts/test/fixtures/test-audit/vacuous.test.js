// Neutral fixture for scripts/lib/test-audit-static.js — invented content
// only (no company code/names), one instance of every rule the scanner
// checks. The first test mirrors the shape of the 2026-07-11 real bug:
// `expect(result.installmentGroupId).not.toBe("group-a")` passed vacuously
// because the property didn't exist on `result` (undefined !== the
// literal is trivially true).

describe('vacuous fixture', () => {
  it('flags a not.toBe on a property that does not exist', () => {
    const result = { groupId: 'group-a' };
    expect(result.wrongName).not.toBe('group-a');
  });

  it('does not flag when the same property is asserted elsewhere', () => {
    const result = { groupId: 'group-a' };
    expect(result.groupId).toBe('group-a');
    expect(result.groupId).not.toBe('group-b');
  });

  it('tautological constant assertion', () => {
    expect(true).toBe(true);
  });

  it('does nothing', () => {});

  it('computes but never asserts', () => {
    const total = 1 + 1;
    console.log(total);
  });

  describe.skip('an entire suite disabled', () => {
    const noop = true;
  });
});
