// Focused guards for the ArkTS failures reported for the recording feature.
// This intentionally does not claim to implement the complete ArkTS linter.
function recordingArktsRules(ts, source) {
  const errors = [];
  const report = (node, message) => errors.push({file:source,start:node.getStart(source),
    length:node.getWidth(source),category:ts.DiagnosticCategory.Error,code:0,messageText:message});
  const propertyModifiers = new Set([ts.SyntaxKind.PublicKeyword,ts.SyntaxKind.PrivateKeyword,
    ts.SyntaxKind.ProtectedKeyword,ts.SyntaxKind.ReadonlyKeyword]);
  function rootName(expression) {
    if (ts.isCallExpression(expression)) {
      const target = expression.expression;
      return ts.isPropertyAccessExpression(target) ? rootName(target.expression) :
        ts.isIdentifier(target) ? target.text : '';
    }
    if (ts.isEtsComponentExpression(expression)) return expression.expression.getText(source);
    return '';
  }
  function visit(node, caught) {
    if (ts.isConstructorDeclaration(node)) {
      for (const p of node.parameters) {
        if (p.modifiers?.some(m=>propertyModifiers.has(m.kind))) {
          report(p,'arkts-no-ctor-prop-decls: declare the field separately and assign it in the constructor');
        }
      }
    }
    if (ts.isThrowStatement(node) && node.expression && ts.isIdentifier(node.expression) && caught.includes(node.expression.text)) {
      report(node,'arkts-limited-throw: normalize a caught value to an Error before throwing');
    }
    if (ts.isStructDeclaration(node) && /^@Entry\b/m.test(node.getText(source))) {
      const build = node.members.find(m=>m.name?.getText(source)==='build');
      const statements = build?.body?.statements || [];
      const containers = new Set(['Stack','Column','Row','Flex','RelativeContainer','Scroll','List','Grid','Navigation','Tabs']);
      if (build && (statements.length!==1 || !ts.isExpressionStatement(statements[0]) ||
        !containers.has(rootName(statements[0].expression)))) {
        report(build,'Entry build must have exactly one root container component');
      }
    }
    const scoped = ts.isCatchClause(node) && node.variableDeclaration && ts.isIdentifier(node.variableDeclaration.name) ?
      caught.concat(node.variableDeclaration.name.text) : caught;
    ts.forEachChild(node,child=>visit(child,scoped));
  }
  visit(source,[]);
  return errors;
}
module.exports = {recordingArktsRules};
