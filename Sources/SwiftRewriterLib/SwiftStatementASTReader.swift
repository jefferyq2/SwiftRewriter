import GrammarModels
import ObjcParserAntlr
import ObjcParser
import Antlr4

public class SwiftStatementASTReader: ObjectiveCParserBaseVisitor<Statement> {
    var expressionReader = SwiftExprASTReader()
    
    public override func visitDeclaration(_ ctx: ObjectiveCParser.DeclarationContext) -> Statement? {
        if let varDecl = ctx.varDeclaration()?.accept(self) {
            return varDecl
        }
        if let funcCall = ctx.functionCallExpression()?.accept(self) {
            return funcCall
        }
        
        return .unknown(UnknownASTContext(context: ctx))
    }
    
    public override func visitFunctionCallExpression(_ ctx: ObjectiveCParser.FunctionCallExpressionContext) -> Statement? {
        guard let ident = ctx.identifier() else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        guard let directDeclarator = ctx.directDeclarator() else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        
        guard let param = VarDeclarationIdentifierNameExtractor.extract(from: directDeclarator) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        
        return
            Statement.expression(
                .postfix(.identifier(ident.getText()),
                         .functionCall(arguments: [.unlabeled(.identifier(param))]
                    ))
            )
    }
    
    public override func visitVarDeclaration(_ ctx: ObjectiveCParser.VarDeclarationContext) -> Statement? {
        return ctx.accept(VarDeclarationExtractor(expressionReader: expressionReader))
    }
    
    public override func visitStatement(_ ctx: ObjectiveCParser.StatementContext) -> Statement? {
        if let cpd = ctx.compoundStatement(), let compound = cpd.accept(compoundStatementVisitor()) {
            return .compound(compound)
        }
        
        return acceptFirst(from: ctx.selectionStatement(),
                           ctx.iterationStatement(),
                           ctx.expressions(),
                           ctx.jumpStatement(),
                           ctx.synchronizedStatement(),
                           ctx.autoreleaseStatement())
            ?? .unknown(UnknownASTContext(context: ctx))
    }
    
    public override func visitExpressions(_ ctx: ObjectiveCParser.ExpressionsContext) -> Statement? {
        let expressions = ctx.expression().compactMap { $0.accept(expressionReader) }
        
        return .expressions(expressions)
    }
    
    public override func visitCompoundStatement(_ ctx: ObjectiveCParser.CompoundStatementContext) -> Statement? {
        guard let compound = ctx.accept(compoundStatementVisitor()) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        
        return .compound(compound)
    }
    
    // MARK: @synchronized / @autoreleasepool
    public override func visitSynchronizedStatement(_ ctx: ObjectiveCParser.SynchronizedStatementContext) -> Statement? {
        guard let expression = ctx.expression()?.accept(expressionReader) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        guard let compoundStatement = ctx.compoundStatement()?.accept(compoundStatementVisitor()) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        
        var doBody: CompoundStatement = []
        
        // Generate an equivalent locking structure as follows:
        
        // do {
        //   let _lockTarget = <expression>
        //   objc_sync_enter(_lockTarget)
        //   defer {
        //     objc_sync_exit(_lockTarget)
        //   }
        //   <statements>
        // }
        
        let lockIdent = "_lockTarget"
        doBody.statements.append(
            .variableDeclaration(identifier: lockIdent, type: .any,
                                 ownership: .strong, isConstant: true,
                                 initialization: expression)
        )
        doBody.statements.append(
            .expression(.postfix(.identifier("objc_sync_enter"),
                                 .functionCall(arguments: [.unlabeled(.identifier(lockIdent))])))
        )
        doBody.statements.append(
            .defer([
                .expression(.postfix(.identifier("objc_sync_exit"),
                                     .functionCall(arguments: [.unlabeled(.identifier(lockIdent))])))
            ])
        )
        
        doBody.statements.append(contentsOf: compoundStatement.statements)
        
        return Statement.do(doBody)
    }
    
    public override func visitAutoreleaseStatement(_ ctx: ObjectiveCParser.AutoreleaseStatementContext) -> Statement? {
        guard let compoundStatement = ctx.compoundStatement()?.accept(compoundStatementVisitor()) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        
        let expression: Expression =
            .postfix(.identifier("autoreleasepool"),
                     .functionCall(arguments: [
                        .unlabeled(.block(parameters: [],
                                          return: .void,
                                          body: compoundStatement))
                        ]))
        
        return .expression(expression)
    }
    
    // MARK: - return / continue / break
    public override func visitJumpStatement(_ ctx: ObjectiveCParser.JumpStatementContext) -> Statement? {
        if ctx.RETURN() != nil {
            return Statement.return(ctx.expression()?.accept(expressionReader))
        }
        if ctx.CONTINUE() != nil {
            return Statement.continue
        }
        if ctx.BREAK() != nil {
            return Statement.break
        }
        
        return .unknown(UnknownASTContext(context: ctx))
    }
    
    // MARK: - if / switch
    public override func visitSelectionStatement(_ ctx: ObjectiveCParser.SelectionStatementContext) -> Statement? {
        if let expression = ctx.expression() {
            guard let expr = expression.accept(expressionReader) else {
                return .unknown(UnknownASTContext(context: ctx))
            }
            guard let body = ctx.ifBody?.accept(compoundStatementVisitor()) else {
                return .unknown(UnknownASTContext(context: ctx))
            }
            
            let elseStmt = ctx.elseBody?.accept(compoundStatementVisitor())
            
            return .if(expr, body: body, else: elseStmt)
        }
        if let switchStmt = ctx.switchStatement() {
            return visitSwitchStatement(switchStmt)
        }
        
        return .unknown(UnknownASTContext(context: ctx))
    }
    
    public override func visitSwitchStatement(_ ctx: ObjectiveCParser.SwitchStatementContext) -> Statement? {
        guard let exp = ctx.expression()?.accept(expressionReader) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        
        var cases: [SwitchCase] = []
        var def: [Statement]?
        
        if let sections = ctx.switchBlock()?.switchSection() {
            for section in sections {
                var statements = section.statement().compactMap { $0.accept(self) }
                
                if statements.count == 1, case .compound(let stmt) = statements[0] {
                    statements = stmt.statements
                }
                
                let labels = section.switchLabel()
                // Default case
                if labels.contains(where: { $0.rangeExpression() == nil }) {
                    def = statements
                } else {
                    let expr =
                        labels
                            .compactMap { $0.rangeExpression() }
                            .compactMap { label in
                                label.accept(expressionReader)
                            }
                    
                    let c =
                        SwitchCase(patterns: expr.map { .expression($0) },
                                   statements: statements)
                    
                    cases.append(c)
                }
            }
        }
        
        // Always emit a default break statement, since switches in Swift must
        // be exhaustive
        if def == nil {
            def = [.break]
        }
        
        return Statement.switch(exp, cases: cases, default: def)
    }
    
    // MARK: - while / do-while / for / for-in
    public override func visitIterationStatement(_ ctx: ObjectiveCParser.IterationStatementContext) -> Statement? {
        if let w = ctx.whileStatement()?.accept(self) {
            return w
        }
        if let f = ctx.forStatement()?.accept(self) {
            return f
        }
        if let forIn = ctx.forInStatement()?.accept(self) {
            return forIn
        }
        
        return .unknown(UnknownASTContext(context: ctx))
    }
    
    public override func visitWhileStatement(_ ctx: ObjectiveCParser.WhileStatementContext) -> Statement? {
        guard let expr = ctx.expression()?.accept(expressionReader) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        guard let body = ctx.statement()?.accept(compoundStatementVisitor()) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        
        return .while(expr, body: body)
    }
    
    public override func visitForStatement(_ ctx: ObjectiveCParser.ForStatementContext) -> Statement? {
        guard let compoundStatement = ctx.statement()?.accept(compoundStatementVisitor()) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        
        // Do a trickery here: We bloat the loop by unrolling it into a plain while
        // loop that is compatible with the original for-loop's behavior
        
        // for(<initExprs>; <condition>; <iteration>)
        let initExpr = ctx.forLoopInitializer()?.accept(VarDeclarationExtractor(expressionReader: expressionReader))
        
        let condition = ctx.expression()?.accept(expressionReader)
        
        // for(<loop>; <condition>; <iteration>)
        let iteration = ctx.expressions()?.accept(self)
        
        // Try to come up with a clean for-in loop with a range
        simplifyFor:
        if let initExpr = initExpr, let condition = condition, let iteration = iteration {
            // Search for inits like 'int i = <value>'
            guard case Statement.variableDeclarations(let decl) = initExpr, decl.count == 1 else {
                break simplifyFor
            }
            let loopVar = decl[0]
            if loopVar.type != .int {
                break simplifyFor
            }
            guard case .constant(let loopStart)? = loopVar.initialization, loopStart.isInteger else {
                break simplifyFor
            }
            
            // Look for conditions of the form 'i < <value>'
            guard case .binary(.identifier(loopVar.identifier), let op, .constant(let loopEnd)) = condition else {
                break simplifyFor
            }
            if !loopEnd.isInteger || (op != .lessThan && op != .lessThanOrEqual) {
                break simplifyFor
            }
            
            // Look for loop iterations of the form 'i++'
            guard case .expressions(let exps) = iteration, exps.count == 1 else {
                break simplifyFor
            }
            guard case .assignment(.identifier(loopVar.identifier), .addAssign, .constant(1)) = exps[0] else {
                break simplifyFor
            }
            
            // Check if the loop variable is not being modified within the loop's
            // body
            for exp in expressions(in: compoundStatement, inspectBlocks: true) {
                if case .assignment(.identifier(loopVar.identifier), _, _) = exp {
                    break simplifyFor
                }
            }
            
            // All good! Simplify now.
            let rangeOp: SwiftOperator = op == .lessThan ? .openRange : .closedRange
            
            return Statement.for(.identifier(loopVar.identifier),
                                 .binary(lhs: .constant(loopStart), op: rangeOp, rhs: .constant(loopEnd)),
                                 body: compoundStatement)
        }
        
        // Come up with a while loop, now
        
        // Loop body
        var body = CompoundStatement()
        if let iteration = iteration {
            body.statements.append(
                .defer([
                    iteration
                    ]
                )
            )
        }
        
        body.statements.append(contentsOf: compoundStatement.statements)
        
        let whileBody = Statement.while(condition ?? .constant(true),
                                        body: body)
        
        // Loop init (pre-loop)
        let bodyWithWhile: Statement
        if let initExpr = initExpr {
            var body = CompoundStatement()
            body.statements.append(initExpr)
            body.statements.append(whileBody)
            
            bodyWithWhile = .compound(body)
        } else {
            bodyWithWhile = whileBody
        }
        
        return bodyWithWhile
    }
    
    public override func visitForInStatement(_ ctx: ObjectiveCParser.ForInStatementContext) -> Statement? {
        guard let identifier = ctx.typeVariableDeclarator()?.accept(VarDeclarationIdentifierNameExtractor()) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        guard let expression = ctx.expression()?.accept(expressionReader) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        guard let body = ctx.statement()?.accept(compoundStatementVisitor()) else {
            return .unknown(UnknownASTContext(context: ctx))
        }
        
        return Statement.for(.identifier(identifier), expression, body: body)
    }
    
    // MARK: - Helper methods
    func compoundStatementVisitor() -> CompoundStatementVisitor {
        return CompoundStatementVisitor(expressionReader: expressionReader)
    }
    
    private func expressions(in compoundStatement: CompoundStatement, inspectBlocks: Bool) -> AnyIterator<Expression> {
        let iterator =
            ExpressionIterator(statement: .compound(compoundStatement),
                               inspectBlocks: inspectBlocks)
        
        return AnyIterator(iterator)
    }
    
    private func expressions(in statement: Statement, inspectBlocks: Bool) -> AnyIterator<Expression> {
        let iterator =
            ExpressionIterator(statement: statement, inspectBlocks: inspectBlocks)
        
        return AnyIterator(iterator)
    }
    
    private func acceptFirst(from rules: ParserRuleContext?...) -> Statement? {
        for rule in rules {
            if let expr = rule?.accept(self) {
                return expr
            }
        }
        
        return nil
    }
    
    // MARK: - Compound statement visitor
    class CompoundStatementVisitor: ObjectiveCParserBaseVisitor<CompoundStatement> {
        var expressionReader = SwiftExprASTReader()
        
        init(expressionReader: SwiftExprASTReader) {
            self.expressionReader = expressionReader
        }
        
        override func visitStatement(_ ctx: ObjectiveCParser.StatementContext) -> CompoundStatement? {
            if let compoundStatement = ctx.compoundStatement() {
                return compoundStatement.accept(self)
            }
            
            let reader = SwiftStatementASTReader()
            reader.expressionReader = expressionReader
            
            if let stmt = reader.visitStatement(ctx) {
                return CompoundStatement(statements: [stmt])
            }
            
            return nil
        }
        
        override func visitCompoundStatement(_ ctx: ObjectiveCParser.CompoundStatementContext) -> CompoundStatement? {
            let reader = SwiftStatementASTReader()
            reader.expressionReader = expressionReader
            
            let rules: [ParserRuleContext] =
                ctx.declaration().map { $0 } + ctx.statement().map { $0 }
            
            return CompoundStatement(statements: rules.compactMap { stmt -> Statement? in
                if let stmt = stmt as? ObjectiveCParser.StatementContext {
                    return reader.visitStatement(stmt)
                }
                if let declaration = stmt as? ObjectiveCParser.DeclarationContext {
                    return reader.visitDeclaration(declaration)
                }
                return .unknown(UnknownASTContext(context: stmt))
            }.flatMap { stmt -> [Statement] in
                // Free compound blocks cannot be declared in Swift
                if case .compound(let inner) = stmt {
                    return inner.statements
                }
                
                return [stmt]
            })
        }
    }
    
    // MARK: - Variable declaration extractor visitor
    private class VarDeclarationExtractor: ObjectiveCParserBaseVisitor<Statement> {
        let typeMapper = TypeMapper(context: TypeContext())
        var expressionReader = SwiftExprASTReader()
        
        init(expressionReader: SwiftExprASTReader) {
            self.expressionReader = expressionReader
        }
        
        override func visitForLoopInitializer(_ ctx: ObjectiveCParser.ForLoopInitializerContext) -> Statement? {
            guard let initDeclarators = ctx.initDeclaratorList()?.initDeclarator() else {
                return .unknown(UnknownASTContext(context: ctx))
            }
            
            let types = VarDeclarationTypeExtractor.extractAll(from: ctx)
            
            var declarations: [StatementVariableDeclaration] = []
            
            for (typeName, initDeclarator) in zip(types, initDeclarators) {
                guard let type = try? ObjcParser(string: typeName).parseObjcType() else {
                    continue
                }
                guard let directDeclarator = initDeclarator.declarator()?.directDeclarator() else {
                    continue
                }
                guard let identifier = directDeclarator.identifier()?.getText() else {
                    continue
                }
                
                let expr = initDeclarator.initializer()?.expression()?.accept(expressionReader)
                
                let swiftType = typeMapper.swiftType(forObjcType: type)
                
                let ownership = SwiftWriter._ownershipPrefix(inType: type)
                let isConstant = SwiftWriter._isConstant(fromType: type)
                
                let declaration =
                    StatementVariableDeclaration(identifier: identifier, type: swiftType,
                                                 ownership: ownership, isConstant: isConstant,
                                                 initialization: expr)
                declarations.append(declaration)
            }
            
            return Statement.variableDeclarations(declarations)
        }
        
        override func visitVarDeclaration(_ ctx: ObjectiveCParser.VarDeclarationContext) -> Statement? {
            guard let initDeclarators = ctx.initDeclaratorList()?.initDeclarator() else {
                return .unknown(UnknownASTContext(context: ctx))
            }
            
            let types = VarDeclarationTypeExtractor.extractAll(from: ctx)
            
            var declarations: [StatementVariableDeclaration] = []
            
            for (typeName, initDeclarator) in zip(types, initDeclarators) {
                guard let type = try? ObjcParser(string: typeName).parseObjcType() else {
                    continue
                }
                guard let directDeclarator = initDeclarator.declarator()?.directDeclarator() else {
                    continue
                }
                guard let identifier = directDeclarator.identifier()?.getText() else {
                    continue
                }
                
                let expr = initDeclarator.initializer()?.expression()?.accept(expressionReader)
                
                let swiftType = typeMapper.swiftType(forObjcType: type)
                
                let ownership = SwiftWriter._ownershipPrefix(inType: type)
                let isConstant = SwiftWriter._isConstant(fromType: type)
                
                let declaration =
                    StatementVariableDeclaration(identifier: identifier, type: swiftType,
                                                 ownership: ownership, isConstant: isConstant,
                                                 initialization: expr)
                declarations.append(declaration)
            }
            
            return Statement.variableDeclarations(declarations)
        }
    }
}