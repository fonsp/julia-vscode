import * as vscode from 'vscode'

export interface ResultContent {
    isIcon: boolean,
    content: string,
    hoverContent: string | vscode.MarkdownString,
    isError: boolean
}

export class Result {
    document: vscode.TextDocument
    text: string
    range: vscode.Range
    content: ResultContent
    decoration: vscode.TextEditorDecorationType
    destroyed: boolean

    constructor(editor: vscode.TextEditor, range: vscode.Range, content: ResultContent) {
        this.range = range
        this.document = editor.document
        this.text = editor.document.getText(this.range)
        this.destroyed = false

        this.setContent(content)
    }

    setContent(content: ResultContent) {
        if (this.destroyed) {
            return
        }

        this.content = content

        if (this.decoration) {
            this.remove()
        }

        const color = new vscode.ThemeColor(content.isError ? 'editorError.foreground' : 'editor.foreground')

        const decoration = {
            before: {
                contentIconPath: undefined,
                contentText: undefined,
                backgroundColor: new vscode.ThemeColor('editorWidget.background'),
                margin: '0 0 0 10px',
                color: color
            },
            rangeBehavior: vscode.DecorationRangeBehavior.OpenClosed
        }

        if (content.isIcon) {
            decoration.before.contentIconPath = content.content
        } else {
            decoration.before.contentText = content.content
        }

        this.decoration = vscode.window.createTextEditorDecorationType(decoration)

        for (const ed of vscode.window.visibleTextEditors) {
            if (ed.document === this.document) {
                ed.setDecorations(this.decoration, [{
                    hoverMessage: this.content.hoverContent,
                    range: this.decorationRange
                }])
            }
        }
    }

    get decorationRange(): vscode.Range {
        return new vscode.Range(this.range.end.translate(0, 9999), this.range.end.translate(0, 9999))
    }

    draw() {
        this.setContent(this.content)
    }

    validate(e: vscode.TextDocumentChangeEvent) {
        if (this.document !== e.document) {
            return true
        }

        for (const change of e.contentChanges) {
            const intersect = change.range.intersection(this.range)
            if (intersect !== undefined && !(intersect.isEmpty && change.text === '\n')) {
                this.remove()
                return false
            }


            if (change.range.end.line < this.range.start.line ||
                (change.range.end.line === this.range.start.line &&
                    change.range.end.character <= this.range.start.character)) {
                const lines = change.text.split('\n')

                const lineOffset = lines.length - 1 - (change.range.end.line - change.range.start.line)
                const charOffset = change.range.end.line === this.range.start.line ?
                    lines[lines.length - 1].length : 0

                this.range = new vscode.Range(
                    this.range.start.translate(lineOffset, charOffset),
                    this.range.end.translate(lineOffset, charOffset)
                )
            }
        }

        if (this.document.getText(this.range) !== this.text) {
            this.remove()
            return false
        }

        return true
    }

    remove(destroy: boolean = false) {
        this.destroyed = destroy
        for (const ed of vscode.window.visibleTextEditors) {
            ed.setDecorations(this.decoration, [])
        }
    }
}

const results: Result[] = []

export function activate(context) {
    context.subscriptions.push(vscode.workspace.onDidChangeTextDocument((e) => validateResults(e)))
    context.subscriptions.push(vscode.window.onDidChangeVisibleTextEditors((editors) => refreshResults(editors)))

    context.subscriptions.push(vscode.commands.registerCommand('language-julia.clearAllInlineResults', removeAll))
    context.subscriptions.push(vscode.commands.registerCommand('language-julia.clearAllInlineResultsInEditor', () => removeAll(vscode.window.activeTextEditor)))
    context.subscriptions.push(vscode.commands.registerCommand('language-julia.clearCurrentInlineResult', () => removeCurrent(vscode.window.activeTextEditor)))
}

export function deactivate() { }

export function addResult(editor: vscode.TextEditor, range: vscode.Range, content: ResultContent) {
    for (let i = results.length - 1; i > -1; i--) {
        const result = results[i]
        if (result.document === editor.document && result.range.intersection(range) !== undefined) {
            removeResult(result)
        }
    }

    const result = new Result(editor, range, content)
    results.push(result)

    return result
}

export function refreshResults(editors: vscode.TextEditor[]) {
    for (const result of results) {
        for (const editor of editors) {
            if (result.document === editor.document) {
                result.draw()
            }
        }
    }
}

export function validateResults(e: vscode.TextDocumentChangeEvent) {
    for (let i = results.length - 1; i > -1; i--) {
        const result = results[i]
        const isvalid = result.validate(e)
        if (!isvalid) {
            removeResult(result)
        }
    }
}

export function removeResult(result: Result) {
    const index = results.indexOf(result)

    if (index > -1) {
        result.remove(true)
        results.splice(index, 1)
    }
}

export function removeAll(editor: vscode.TextEditor | null = null) {
    for (let i = results.length - 1; i > -1; i--) {
        const result = results[i]
        if (editor === null || result.document === editor.document) {
            removeResult(result)
        }
    }
}

export function removeCurrent(editor: vscode.TextEditor) {
    for (const selection of editor.selections) {
        for (let i = results.length - 1; i > -1; i--) {
            const result = results[i]
            const intersect = selection.intersection(result.range)
            if (result.document === editor.document && intersect !== undefined) {
                result.remove()
            }
        }
    }
}
