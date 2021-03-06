
-- The findCurrentNode() depends on the names of the
-- local variables in the nngraph.gModule source code.
local function findCurrentNode()
    for level = 2, math.huge do
        local info = debug.getinfo(level, "n")
        if info == nil then
            return nil
        end

        local funcName = info.name
        if funcName == "neteval" then
            local varName, node = debug.getlocal(level, 1)
            if varName == "node" then
                return node
            end
        end
    end
end

-- Runs the func and calls onError(failedNode, ...) on an error.
-- The stack trace is inspected to find the failedNode.
local function runChecked(func, onError, ...)
    -- The current node needs to be searched-for, before unrolling the stack.
    local failedNode
    local function errorHandler(message)
        -- The stack traceback is added only if not already present.
        if not string.find(message, 'stack traceback:\n', 1, true) then
            message = debug.traceback(message, 2)
        end
        failedNode = findCurrentNode()
        return message
    end

    local ok, result = xpcall(func, errorHandler)
    if ok then
        return result
    end

    onError(failedNode, ...)
    -- Passing the level 0 avoids adding an additional error position info
    -- to the message.
    error(result, 0)
end

local function customToDot(graph, title, failedNode)
    local str = graph:todot(title)
    if not failedNode then
        return str
    end

    local failedNodeId = nil
    for i, node in ipairs(graph.nodes) do
        if node.data == failedNode.data then
            failedNodeId = node.id
            break
        end
    end

    if failedNodeId ~= nil then
        -- The closing '}' is removed.
        -- And red fillcolor is specified for the failedNode.
        str = string.gsub(str, '}%s*$', '')
        str = str .. string.format('n%s[style=filled, fillcolor=red];\n}',
            failedNodeId)
    end
    return str
end

local function saveSvg(svgPathPrefix, dotStr)
    io.stderr:write(string.format("saving %s.svg\n", svgPathPrefix))
    local dotPath = svgPathPrefix .. '.dot'
    local dotFile = io.open(dotPath, 'w')
    dotFile:write(dotStr)
    dotFile:close()

    local svgPath = svgPathPrefix .. '.svg'
    local cmd = string.format('dot -Tsvg -o %s %s', svgPath, dotPath)
    os.execute(cmd)
end

local function onError(failedNode, gmodule)
    local nInputs = gmodule.nInputs or #gmodule.innode.children
    local svgPathPrefix = gmodule.name or string.format(
        'nngraph_%sin_%sout', nInputs, #gmodule.outnode.children)
    local dotStr = customToDot(gmodule.fg, svgPathPrefix, failedNode)
    saveSvg(svgPathPrefix, dotStr)
end

local origFuncs = {
    runForwardFunction = nn.gModule.runForwardFunction,
    updateGradInput = nn.gModule.updateGradInput,
    accGradParameters = nn.gModule.accGradParameters,
}

-- When debug is enabled,
-- a gmodule.name .. '.svg' will be saved
-- if an exception occurs in a graph execution.
-- The problematic node will be marked by red color.
function nngraph.setDebug(enable)
    if not enable then
        -- When debug is disabled,
        -- the origFuncs are restored on nn.gModule.
        for funcName, origFunc in pairs(origFuncs) do
            nn.gModule[funcName] = origFunc
        end
        return
    end

    for funcName, origFunc in pairs(origFuncs) do
        nn.gModule[funcName] = function(...)
            local args = {...}
            local gmodule = args[1]
            return runChecked(function()
                return origFunc(unpack(args))
            end, onError, gmodule)
        end
    end
end
