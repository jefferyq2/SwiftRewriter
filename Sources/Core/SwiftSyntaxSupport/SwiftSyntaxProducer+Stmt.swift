import SwiftSyntax
import Intentions
import SwiftAST

extension SwiftSyntaxProducer {
    typealias StatementBlockProducer = (SwiftSyntaxProducer) -> CodeBlockItemSyntax.Item?
    
    // TODO: Consider reducing code duplication within `generateStatement` and
    // `_generateStatements`
    
    /// Generates a code block for the given statement.
    /// This code block might have zero, one or more sub-statements, depending
    /// on the properties of the given statement, e.g. expression statements
    /// which feature zero elements in the expressions array result in an empty
    /// code block.
    ///
    /// This method is provided more as an inspector of generation of syntax
    /// elements for particular statements, and is not used internally by the
    /// syntax producer while generating whole files.
    ///
    /// - Returns: A code block containing the statements generated by the
    /// statement provided.
    public func generateStatement(_ statement: Statement) -> CodeBlockSyntax {
        if let statement = statement as? CompoundStatement {
            return generateCompound(statement)
        }
        
        var syntax = CodeBlockSyntax()

        indent()
        defer {
            deindent()
        }
        
        let stmts = generateStatementBlockItems(statement)
        
        for (i, stmt) in stmts.enumerated() {
            if i > 0 {
                addExtraLeading(.newlines(1))
            }
            
            if let stmtSyntax = stmt(self) {
                syntax = syntax.addStatement(.init(item: stmtSyntax))
            }
        }

        return syntax
    }
    
    func generateCompound(_ compoundStmt: CompoundStatement) -> CodeBlockSyntax {
        var syntax = CodeBlockSyntax()

        var leftBrace = prepareStartToken(.leftBrace)
        indent()

        // Apply comments as a trailing trivia for the leading brace
        if !compoundStmt.comments.isEmpty {
            leftBrace = leftBrace.withTrailingTrivia(
                .newlines(1)
                    + indentation()
                    + toCommentsTrivia(
                        compoundStmt.comments,
                        addNewLineAfter: !compoundStmt.isEmpty
                    )
            )
        }
        syntax = syntax.withLeftBrace(leftBrace)
        
        let stmts = _generateStatements(compoundStmt.statements)
        
        for stmt in stmts {
            syntax = syntax.addStatement(stmt)
        }

        deindent()

        syntax = syntax.withRightBrace(
            .rightBrace
                .onNewline()
                .addingLeadingTrivia(indentation())
                .withExtraLeading(consuming: &extraLeading)
        )

        return syntax
    }
    
    func _generateStatements(_ stmtList: [Statement]) -> [CodeBlockItemSyntax] {
        var items: [CodeBlockItemSyntax] = []
        
        for (i, stmt) in stmtList.enumerated() {
            let stmtSyntax = generateStatementBlockItems(stmt)
            
            for item in stmtSyntax {
                addExtraLeading(.newlines(1) + indentation())

                if let syntax = item(self) {
                    items.append(.init(item: syntax))
                }
            }
            
            if i < stmtList.count - 1
                && _shouldEmitNewlineSpacing(between: stmt,
                                             stmt2: stmtList[i + 1]) {
                
                addExtraLeading(.newlines(1))
            }
        }
        
        return items
    }
    
    private func _shouldEmitNewlineSpacing(between stmt1: Statement,
                                           stmt2: Statement) -> Bool {
        
        switch (stmt1, stmt2) {
        case (is ExpressionsStatement, is ExpressionsStatement):
            return false
        case (is VariableDeclarationsStatement, is ExpressionsStatement),
             (is VariableDeclarationsStatement, is VariableDeclarationsStatement):
            return false
            
        default:
            return true
        }
    }
    
    func generateStatementBlockItems(_ stmt: Statement) -> [StatementBlockProducer] {
        var genList: [StatementBlockProducer]
        
        switch stmt {
        case let stmt as StatementKindType:
            genList = generateStatementKind(stmt.statementKind)

        default:
            assertionFailure("Found unknown statement syntax node type \(type(of: stmt))")
            genList = [{ _ in .expr(MissingExprSyntax().asExprSyntax) }]
        }
        
        var leadingComments = stmt.comments
        if let label = stmt.label, !stmt.isLabelableStatementType {
            leadingComments.append(.line("// \(label):"))
        }
        
        genList = applyingLeadingComments(leadingComments, toList: genList)
        genList = applyingTrailingComment(stmt.trailingComment, toList: genList)
        
        return genList
    }

    private func generateStatementKind(_ statementKind: StatementKind) -> [StatementBlockProducer] {

        func prefixLabel<S: StmtSyntaxProtocol>(
            label: String?,
            _ producer: SwiftSyntaxProducer,
            _ generator: (SwiftSyntaxProducer) -> S
        ) -> StmtSyntax {

            guard let label = label else {
                return StmtSyntax(generator(producer))
            }

            let labelToken = prepareStartToken(.identifier(label))

            let builder = LabeledStmtBuilder(label: (labelToken, labelText: label, colon: .colon))

            producer.addExtraLeading(.newlines(1) + producer.indentation())

            return builder.buildSyntax(generator(producer))
        }

        func prefixLabel<S: StmtSyntaxProtocol>(
            _ stmt: Statement,
            _ producer: SwiftSyntaxProducer,
            _ generator: (SwiftSyntaxProducer) -> S
        ) -> StmtSyntax {

            return prefixLabel(label: stmt.label, producer, generator)
        }

        switch statementKind {
        case .return(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateReturn(stmt) }).inCodeBlockItem()
            }]
            
        case .continue(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateContinue(stmt) }).inCodeBlockItem()
            }]
            
        case .break(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateBreak(stmt) }).inCodeBlockItem()
            }]
            
        case .fallthrough(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateFallthrough(stmt) }).inCodeBlockItem()
            }]
            
        case .expressions(let stmt):
            return generateExpressions(stmt)
            
        case .variableDeclarations(let stmt):
            return generateVariableDeclarations(stmt)
            
        case .if(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateIfStmt(stmt) }).inCodeBlockItem()
            }]
            
        case .switch(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateSwitchStmt(stmt) }).inCodeBlockItem()
            }]
            
        case .while(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateWhileStmt(stmt) }).inCodeBlockItem()
            }]
            
        case .do(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateDo(stmt) }).inCodeBlockItem()
            }]
            
        case .repeatWhile(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateDoWhileStmt(stmt) }).inCodeBlockItem()
            }]
            
        case .for(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateForIn(stmt) }).inCodeBlockItem()
            }]
            
        case .defer(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateDefer(stmt) }).inCodeBlockItem()
            }]
            
        case .compound(let stmt):
            return stmt.statements.flatMap(generateStatementBlockItems)

        case .localFunction(let stmt):
            return [{ $0.generateLocalFunction(stmt).inCodeBlockItem() }]

        case .throw(let stmt):
            return [{ producer in
                prefixLabel(stmt, producer, { $0.generateThrow(stmt) }).inCodeBlockItem()
            }]
            
        case .unknown(let stmt):
            return [self.generateUnknown(stmt)]
        }
    }
    
    private func applyingLeadingComments(
        _ comments: [SwiftComment],
        toList list: [StatementBlockProducer]
    ) -> [StatementBlockProducer] {
        
        guard !comments.isEmpty, let first = list.first else {
            return list
        }
        
        var list = list
        
        list[0] = {
            $0.addComments(comments)
            
            return first($0)
        }
        
        return list
    }
    
    private func applyingTrailingComment(
        _ comment: SwiftComment?,
        toList list: [StatementBlockProducer]
    ) -> [StatementBlockProducer] {

        guard let comment = comment, let last = list.last else {
            return list
        }
        let trivia = toCommentTrivia(comment)
        
        var list = list
        
        list[list.count - 1] = {
            return last($0)?.withTrailingTrivia(.spaces(1) + trivia)
        }
        
        return list
    }
    
    /// Processes an unknown statement, adding the 
    func generateUnknown(_ unknown: UnknownStatement) -> StatementBlockProducer {
        return {
            let indent = $0.indentationString()
        
            $0.addExtraLeading(
                .blockComment("""
                    /*
                    \(indent)\(unknown.context.description)
                    \(indent)*/
                    """
                )
            )

            return nil
        }
    }
    
    func generateExpressions(_ stmt: ExpressionsStatement) -> [StatementBlockProducer] {
        stmt.expressions
            .map { exp -> (SwiftSyntaxProducer) -> CodeBlockItemSyntax.Item in
                return {
                    if $0.settings.outputExpressionTypes {
                        let type = "// type: \(exp.resolvedType ?? "<nil>")"
                        
                        $0.addExtraLeading(Trivia.lineComment(type))
                        $0.addExtraLeading(.newlines(1) + $0.indentation())
                    }
                    
                    return $0.generateExpression(exp).inCodeBlockItem()
                }
            }
    }
    
    func generateVariableDeclarations(_ stmt: VariableDeclarationsStatement) -> [StatementBlockProducer] {
        if stmt.decl.isEmpty {
            return []
        }
        
        return varDeclGenerator
            .generateVariableDeclarations(stmt)
            .enumerated()
            .map { (i, decl) in
                return {
                    if $0.settings.outputExpressionTypes {
                        let declType = "// decl type: \(stmt.decl[i].type)"
                        
                        $0.addExtraLeading(Trivia.lineComment(declType))
                        $0.addExtraLeading(.newlines(1) + $0.indentation())

                        if let exp = stmt.decl[i].initialization {
                            let initType = "// init type: \(exp.resolvedType ?? "<nil>")"
                            
                            $0.addExtraLeading(Trivia.lineComment(initType))
                            $0.addExtraLeading(.newlines(1) + $0.indentation())
                        }
                    }

                    return decl().inCodeBlockItem()
                }
            }
    }
    
    public func generateReturn(_ stmt: ReturnStatement) -> ReturnStmtSyntax {
        let syntax: ReturnStmtSyntax

        let returnKeywordSyntax = prepareStartToken(.return)

        if let exp = stmt.exp {
            syntax = ReturnStmtSyntax(
                returnKeyword: returnKeywordSyntax.addingTrailingSpace(),
                expression: generateExpression(exp)
            )
        } else {
            syntax = ReturnStmtSyntax(returnKeyword: returnKeywordSyntax)
        }
        
        return syntax
    }
    
    public func generateContinue(_ stmt: ContinueStatement) -> ContinueStmtSyntax {
        let syntax: ContinueStmtSyntax

        if let label = stmt.targetLabel {
            syntax = ContinueStmtSyntax(
                continueKeyword: prepareStartToken(.continue).withTrailingSpace(),
                label: label
            )
        } else {
            syntax = ContinueStmtSyntax(
                continueKeyword: prepareStartToken(.continue)
            )
        }

        return syntax
    }
    
    public func generateBreak(_ stmt: BreakStatement) -> BreakStmtSyntax {
        let syntax: BreakStmtSyntax

        if let label = stmt.targetLabel {
            syntax = BreakStmtSyntax(
                breakKeyword: prepareStartToken(.break).withTrailingSpace(),
                label: label
            )
        } else {
            syntax = BreakStmtSyntax(
                breakKeyword: prepareStartToken(.break)
            )
        }

        return syntax
    }
    
    public func generateFallthrough(_ stmt: FallthroughStatement) -> FallthroughStmtSyntax {
        let syntax = FallthroughStmtSyntax(
            fallthroughKeyword: prepareStartToken(.fallthrough)
        )

        return syntax
    }
    
    public func generateIfStmt(_ stmt: IfStatement) -> IfStmtSyntax {
        var syntax = IfStmtSyntax(conditions: [])
        
        syntax = syntax.withIfKeyword(
            prepareStartToken(.if).withTrailingSpace()
        )
        
        if let pattern = stmt.pattern {
            let bindingConditionSyntax = OptionalBindingConditionSyntax(
                letOrVarKeyword: prepareStartToken(.let).withTrailingSpace(),
                pattern: generatePattern(pattern),
                initializer: .init(
                    equal: .equal.addingSurroundingSpaces(),
                    value: generateExpression(stmt.exp)
                )
            )

            let conditionSyntax = ConditionElementSyntax(condition: .optionalBinding(bindingConditionSyntax))

            syntax = syntax.addCondition(conditionSyntax.withTrailingSpace())
        } else {
            let conditionSyntax = ConditionElementSyntax(
                condition: .expression(
                    generateExpression(stmt.exp).withTrailingSpace()
                )
            )

            syntax = syntax.addCondition(conditionSyntax)
        }
        
        syntax = syntax.withBody(generateCompound(stmt.body))
        
        if let _else = stmt.elseBody {
            syntax = syntax.withElseKeyword(
                .else.addingSurroundingSpaces()
            )
            
            if _else.statements.count == 1, let elseIfStmt = _else.statements[0] as? IfStatement {
                syntax = syntax.withElseBody(.init(generateIfStmt(elseIfStmt)))
            } else {
                syntax = syntax.withElseBody(.init(generateCompound(_else)))
            }
        }

        return syntax
    }
    
    public func generateSwitchStmt(_ stmt: SwitchStatement) -> SwitchStmtSyntax {
        let switchKeyword = prepareStartToken(.switch).withTrailingSpace()
        let expSyntax = generateExpression(stmt.exp)

        var syntaxes: [SwitchCaseListSyntax.Element] = []
        
        for _case in stmt.cases {
            addExtraLeading(.newlines(1) + indentation())
            
            let switchCase = generateSwitchCase(_case)
            
            syntaxes.append(.switchCase(switchCase))
        }
        
        if let defaultCase = stmt.defaultCase {
            addExtraLeading(.newlines(1) + indentation())
            
            let switchCase = generateSwitchDefaultCase(defaultCase)
            
            syntaxes.append(.switchCase(switchCase))
        }

        let syntax = SwitchStmtSyntax(
            switchKeyword: switchKeyword,
            expression: expSyntax,
            leftBrace: .leftBrace.withLeadingSpace(),
            cases: .init(syntaxes),
            rightBrace: .rightBrace.withLeadingTrivia(.newlines(1) + indentation())
        )

        return syntax
    }
    
    public func generateSwitchCase(
        _ switchCase: SwitchCase
    ) -> SwitchCaseSyntax {
        
        var syntax = SwitchCaseSyntax(
            label: generateSwitchCaseLabel(switchCase)
        )

        indent()
        defer {
            deindent()
        }
        
        let stmts = _generateStatements(switchCase.statements)
        
        for stmt in stmts {
            syntax = syntax.addStatement(stmt) // builder.useStatement(stmt)
        }

        return syntax
    }
    
    public func generateSwitchDefaultCase(
        _ defaultCase: SwitchDefaultCase
    ) -> SwitchCaseSyntax {
        
        var syntax = SwitchCaseSyntax(
            label: .default(
                .init(defaultKeyword: prepareStartToken(.default))
            )
        )

        indent()
        defer {
            deindent()
        }
        
        let stmts = _generateStatements(defaultCase.statements)
        
        for stmt in stmts {
            syntax = syntax.addStatement(stmt) // builder.useStatement(stmt)
        }

        return syntax
    }
    
    public func generateSwitchCaseLabel(_ _case: SwitchCase) -> SwitchCaseSyntax.Label {
        var syntax = SwitchCaseLabelSyntax(
            caseKeyword: prepareStartToken(.case).withTrailingSpace()
        )

        iterateWithComma(_case.patterns) { (item, hasComma) in
            var itemSyntax = CaseItemSyntax(pattern: generatePattern(item))

            itemSyntax = itemSyntax.withPattern(generatePattern(item))
            
            if hasComma {
                itemSyntax = itemSyntax.withTrailingComma(
                    .comma.withTrailingSpace()
                )
            }

            syntax = syntax.addCaseItem(itemSyntax)
        }

        return .case(syntax)
    }
    
    public func generateWhileStmt(_ stmt: WhileStatement) -> WhileStmtSyntax {
        let syntax = WhileStmtSyntax(
            whileKeyword: prepareStartToken(.while).withTrailingSpace(),
            conditions: [ConditionElementSyntax(
                condition: .expression(generateExpression(stmt.exp).withTrailingSpace())
            )],
            body: generateCompound(stmt.body)
        )

        return syntax
    }
    
    public func generateDoWhileStmt(_ stmt: RepeatWhileStatement) -> RepeatWhileStmtSyntax {
        let syntax = RepeatWhileStmtSyntax(
            repeatKeyword: prepareStartToken(.repeat).withTrailingSpace(),
            body: generateCompound(stmt.body),
            whileKeyword: prepareStartToken(.while).addingSurroundingSpaces(),
            condition: generateExpression(stmt.exp)
        )

        return syntax
    }
    
    public func generateForIn(_ stmt: ForStatement) -> ForInStmtSyntax {
        let syntax = ForInStmtSyntax(
            forKeyword: prepareStartToken(.for).withTrailingSpace(),
            pattern: generatePattern(stmt.pattern),
            inKeyword: .in.addingSurroundingSpaces(),
            sequenceExpr: generateExpression(stmt.exp).withTrailingSpace(),
            body: generateCompound(stmt.body)
        )
        
        return syntax
    }
    
    public func generateDo(_ stmt: DoStatement) -> DoStmtSyntax {
        let doKeyword = prepareStartToken(.do).withTrailingSpace()
        let bodySyntax = generateCompound(stmt.body)
        let catchClausesListSyntax = CatchClauseListSyntax(stmt.catchBlocks.map({ generateCatchBlock($0).withLeadingSpace() }))

        let syntax = DoStmtSyntax(
            doKeyword: doKeyword,
            body: bodySyntax,
            catchClauses: catchClausesListSyntax
        )

        return syntax
    }

    public func generateCatchBlock(_ catchBlock: CatchBlock) -> CatchClauseSyntax {
        var syntax = CatchClauseSyntax(
            catchKeyword: prepareStartToken(.catch).withTrailingSpace()
        )

        if let pattern = catchBlock.pattern {
            syntax = syntax.addCatchItem(
                generateCatchItem(from: pattern)
                .withTrailingSpace()
            )
        }

        syntax = syntax.withBody(generateCompound(catchBlock.body))

        return syntax
    }

    public func generateCatchItem(from pattern: Pattern, hasComma: Bool = false) -> CatchItemSyntax {
        var syntax = CatchItemSyntax(
            pattern: generateValueBindingPattern(pattern)
        )

        if hasComma {
            syntax = syntax.withTrailingComma(.comma)
        }

        return syntax
    }
    
    public func generateDefer(_ stmt: DeferStatement) -> DeferStmtSyntax {
        let syntax = DeferStmtSyntax(
            deferKeyword: prepareStartToken(.defer).withTrailingSpace(),
            body: generateCompound(stmt.body)
        )
        
        return syntax
    }

    public func generateLocalFunction(_ stmt: LocalFunctionStatement) -> FunctionDeclSyntax {
        let syntax = FunctionDeclSyntax(
            funcKeyword: prepareStartToken(.func).withTrailingSpace(),
            identifier: makeIdentifier(stmt.function.identifier),
            signature: generateSignature(stmt.function.signature).withTrailingSpace(),
            body: generateCompound(stmt.function.body)
        )
        
        return syntax
    }

    public func generateThrow(_ stmt: ThrowStatement) -> ThrowStmtSyntax {
        let syntax = ThrowStmtSyntax(
            throwKeyword: prepareStartToken(.throw).withTrailingSpace(),
            expression: generateExpression(stmt.exp)
        )

        return syntax
    }
    
    public func generatePattern(_ pattern: Pattern) -> PatternSyntax {
        switch pattern {
        case .identifier(let ident):
            return IdentifierPatternSyntax(
                identifier: makeIdentifier(ident)
            ).asPatternSyntax
        
        case .wildcard:
            return WildcardPatternSyntax().asPatternSyntax
            
        case .expression(let exp):
            return ExpressionPatternSyntax(
                expression: generateExpression(exp)
            ).asPatternSyntax
            
        case .tuple(let items):
            var syntax = TuplePatternSyntax()

            iterateWithComma(items) { (item, hasComma) in
                var elementSyntax = TuplePatternElementSyntax(pattern: generatePattern(item))
                    
                if hasComma {
                    elementSyntax = elementSyntax.withTrailingComma(
                        .comma.withTrailingSpace()
                    )
                }
                syntax = syntax.addElement(elementSyntax)
            }

            return syntax.asPatternSyntax
        }
    }
    
    public func generateValueBindingPattern(_ pattern: Pattern, isConstant: Bool = true) -> ValueBindingPatternSyntax {
        let letOrVarKeyword: TokenSyntax

        if isConstant {
            letOrVarKeyword = prepareStartToken(.let).withTrailingSpace()
        } else {
            letOrVarKeyword = prepareStartToken(.var).withTrailingSpace()
        }

        let syntax = ValueBindingPatternSyntax(
            letOrVarKeyword: letOrVarKeyword,
            valuePattern: generatePattern(pattern)
        )
        
        return syntax
    }
}
