package org.eclipse.xtend.java2xtend

import com.google.common.base.Optional
import java.beans.Introspector
import java.util.List
import org.eclipse.jdt.core.dom.ASTNode
import org.eclipse.jdt.core.dom.ASTVisitor
import org.eclipse.jdt.core.dom.Block
import org.eclipse.jdt.core.dom.ChildListPropertyDescriptor
import org.eclipse.jdt.core.dom.CustomInfixExpression
import org.eclipse.jdt.core.dom.EnhancedForStatement
import org.eclipse.jdt.core.dom.Expression
import org.eclipse.jdt.core.dom.ForStatement
import org.eclipse.jdt.core.dom.InfixExpression
import org.eclipse.jdt.core.dom.MethodInvocation
import org.eclipse.jdt.core.dom.NameWrapper
import org.eclipse.jdt.core.dom.Statement
import org.eclipse.jdt.core.dom.TypeLiteral

import static org.eclipse.jdt.core.dom.ASTNode.*

import static extension java.lang.Character.*
import static extension org.eclipse.xtend.java2xtend.ConvertingVisitor.*
import org.eclipse.jdt.core.dom.PrefixExpression

class ConvertingVisitor extends ASTVisitor {

	override visit(EnhancedForStatement node) {
		val ast = node.AST
		node.parameter.type = ast.newSimpleType(new NameWrapper(ast, ''))
		true
	}

	override visit(TypeLiteral qname) {
		val methodCall = qname.AST.newMethodInvocation
		methodCall.name = qname.AST.newSimpleName("typeof")
		methodCall.arguments.add(qname.AST.newSimpleName(qname.type.toString))
		replaceNode(qname, methodCall)
		false
	}
	
	private def toFieldAccess(MethodInvocation node, String newName) {
		if (node.expression == null) {
			new NameWrapper(node.AST, newName)
		} else {
			node.AST.newFieldAccess() => [ f |
				f.expression = node.expression.copy
				f.name = new NameWrapper(node.AST, newName)
			]
		}
	}
	
	override visit(MethodInvocation node) {
		if (node.expression?.toString == "System.out") {
			if (node.name.toString.startsWith("print")) {
				node.expression.delete
				return true
			}
		}
		
		if (node.name.identifier == 'equals' && node.arguments.size === 1) {
			var ASTNode replace = node;
			var operator = '=='
			if(#[node.parent].filter(typeof(PrefixExpression)).exists[it.operator == PrefixExpression$Operator::NOT]) {
				replace = node.parent;
				operator = '!='
			}
			
			val newInfix = new CustomInfixExpression(node.AST, operator)
			newInfix.leftOperand = node.expression.copy
			newInfix.rightOperand = (node.arguments.head as Expression).copy
			replaceNode(replace, newInfix)
			return true
		}
		
		val getterPrefixes = #['is','get','has']

		val name = node.name;
		val identifier = name.identifier
		if (node.arguments.empty) {
			val newIdentifier = Optional::fromNullable(getterPrefixes.filter [
				identifier.startsWith(it) 
					&& identifier.length > it.length 
					&& identifier.charAt(it.length).upperCase
			].map[
				Introspector::decapitalize(identifier.substring(it.length))
			].head)
						
			val newName = newIdentifier.or(identifier)
			
			val newNode = toFieldAccess(node, newName)
			replaceNode(node, newNode)
			return true
		}else if(node.arguments.size == 1 && identifier.startsWith("set")) {
			val newName = Introspector::decapitalize(identifier.substring("set".length))
			val newNode = node.AST.newAssignment => [a|
				a.leftHandSide = toFieldAccess(node, newName)
				a.rightHandSide = (node.arguments.head as Expression).copy
			]
			replaceNode(node, newNode)
		}
		true
	}
	override visit(ForStatement node) {
		val xfor = XtendFor::create(node)
		if (xfor != null)
			return super.visit(node)
		//need to convert to while loop
		val block = node.AST.newBlock
		node.initializers
			.map[it as Expression]
			.map[node.AST.newExpressionStatement(it.copy)]
			.forEach[
				it.accept(this)
				block.statements.add(it)
			]
		val whileStmt = node.AST.newWhileStatement
		whileStmt.expression = node.expression.copy
		whileStmt.body = node.body.copy as Block => [
			statements.addAll(node.updaters.map[it as Expression].map[node.AST.newExpressionStatement(it.copy)])
		]
		block.statements.add(whileStmt)
		replaceNode(node, block)		
		true
	}
	
	override visit(InfixExpression exp) {
		switch exp.operator {
			case InfixExpression$Operator::EQUALS: 
				replaceOp(exp, '===')
			case InfixExpression$Operator::NOT_EQUALS: 
				replaceOp(exp, '!==')
			case InfixExpression$Operator::AND:
				replaceOpWithMethod(exp, 'bitwiseAnd')
			case InfixExpression$Operator::OR:
				replaceOpWithMethod(exp, 'bitwiseOr')
			case InfixExpression$Operator::XOR:
				replaceOpWithMethod(exp, 'bitwiseXor')
		} 
		true
	} 

	private def replaceOp(InfixExpression exp, String op) {
		val newInfix = new CustomInfixExpression(exp.AST, op)
		newInfix.leftOperand = exp.leftOperand.copy
		newInfix.rightOperand = exp.rightOperand.copy
		replaceNode(exp, newInfix)
	}
	
	private def replaceOpWithMethod(InfixExpression exp, String name) {
		val newNode = exp.AST.newMethodInvocation => [m|
			m.expression = exp.leftOperand.copy
			m.name.identifier = name
			m.arguments.add(exp.rightOperand.copy)
		]
		replaceNode(exp, newNode)		
	}
	
	def static copy(Expression exp) {
		copySubtree(exp.AST, exp) as Expression
	}
	def static copy(Statement exp) {
		copySubtree(exp.AST, exp) as Statement
	}
	
	private def replaceNode(ASTNode node, ASTNode exp) {
		val parent = node.parent
		val location = node.locationInParent
		try{			
			if (location instanceof ChildListPropertyDescriptor) {
				// There's a convention in the AST classes:
				// For a ChildListPropertyDescriptor.id string value there's a 
				// corresponding no-arg method for retrieving the list eg. MethodInvocation.arguments().
				val method = parent.class.getMethod(location.id)
				val list = method.invoke(parent) as List<Object>
				val index = list.indexOf(node)
				if(index >= 0){
					list.set(index, exp);
				}else{
					throw new IllegalArgumentException(node +" not found in "+list+" ("+index+")")
				}
			} else {
				parent.setStructuralProperty(location, exp)
			}
			exp.accept(this)		
		}catch(Exception ex){
			throw new RuntimeException("Failed to replace node: "+node+" with "+exp+" in "+parent, ex)
		}
	}

}
