#!/usr/bin/env jq
# This is a collection of filters for `jq`, intended to manipulate JSON objects
# into JSON representing a website index, for further processing in a template.

# Convert "truthy" value to actual boolean.
def bool:
    [. == (null,false,0,{},[])] | any | not
;

# Is a given array at least length $n?
def at_least($n):
    (. | length) >= $n
;

# Generate this object and all its descendants.
def entries:
    ., recurse(.contents?[]?)
;

# Wrap an object in other objects so that the original object exists at a
# particular "path". Like `{} | setpath(["a","b"], …)`, but instead of making
# objects like `{"a":{"b":…}}`, this makes objects like `{"name":"a",
# "contents":[{"name":"b",…}]}`. We use `name` and `contents` to be compatible
# with the output of the `tree` program on the shell. 
def tree($path):
    if $path | at_least(2)
    then { "contents": [ tree($path[1:]) ] }
    else .
    end | .name = $path[0]
;

# Merge an array of page objects into a single page object.
def merge: 
    map(to_entries) | add | group_by(.key) | map(
        { "key": (.[0].key)
        , "value": (
            if .[0].key == "contents"
            then [ .[].value ] | add | group_by(.name) | map(merge)
            elif [ .[].value == .[0].value ] | all
            then .[0].value
            else error("can't merge incompatible values for key '\(.[0].key)'")
            end
        ) }
    ) | from_entries
;

# Flatten an object into a 1-layer object, such that
# '{"a":["b"]}}' becomes '{"a-0":"b"}'. This is used as a hacky way to pass
# arguments from the JSON index directly from the Makefile to the proper
# recipe, without an additional file.
def flat_obj:
    [   path(..) as $p 
        | getpath($p) | select([(. | type) != ("object", "array")] | all)
        | { ($p|join("-")):. }
    ] | add
;

# Add paths to each object, that is, the names of the ancestors.
def directory:
    def f($d): .dir=($d|join("/")) | .name as $n | .contents[]?|=f($d+[$n]);
    f([])
;

# Every leaf node gets a basename, eg name without extension.
def basename:
    (entries | select(has("contents") | not)) |= (
        .basename = (.name | sub(".([A-z]*)$";""))
    )
;

# Any page gets its target formats.
def formats($all_formats):
    entries |= (
        .formats = [
            (.make // empty) |
            if . == "null" then empty else . end | # fix for wrong YAML parse
            if (. | type) == "array" then .[] else . end |
            tostring | ascii_downcase |
            if [. == $all_formats[]] | any then . 
            elif . == "all" then $all_formats[] 
            else error("unrecognized format: \(.)") 
            end
        ]
    )
;

# Any page is linked to its first target format.
def link:
    (entries | select(.formats | at_least(1))) |= (
        .link = "\(.dir)/\(.basename).\(.formats[0])"
    )
;

# Front matter is the page to be associated with the enclosing directory rather
# than itself.
def frontmatter:
    (entries | select(has("contents"))) |= (
        (.frontmatter = [.contents[] | select(.frontmatter | bool)][0]) |
        (.contents = .contents - [.frontmatter])
    )
;

# Any page that has no link should be excluded from the index. It would be
# nicer if we could remove in one swoop with `entries | ... |= empty`. It only
# works sometimes, presumably since we'd change the objects we'd iterate over.
def clean:
    if has("contents") then .contents |= map(clean)
    elif has("link")   then .
    else empty end
;


# Add links to the next and previous page for every linked page.
def navigation:
    def f($paths; $i; $j; $key):
        setpath($paths[$i]+[$key];
            getpath($paths[$j]) | {link,title,"source":"\(.dir)/\(.name)"}
        )
    ;
    [ path(entries | select(.formats | contains(["html"]))) ] as $paths
    | ($paths | length) as $n
    | reduce range(0; $n-1) as $i (.; f($paths; $i; $i+1; "next"))
    | reduce range(1; $n)   as $i (.; f($paths; $i; $i-1; "prev"))
;


# Sort content first according to sort order in metadata.
def sorting:
    (entries | select(has("contents")) | .contents) |= (
        sort_by(.[.sortby // ""] // .sort // .title // .name)
    )
;

# Add a note that tells us whether this has only children who have no more
# subchildren.
def annotate_leaves:
    (entries | select(has("contents"))) |= (
        .only_leaves = (.contents | all(has("contents") | not))
    )
;

# Combines the given stream of JSON objects by merging them, and performs the
# given operations to turn it into a proper index.
def index($all_formats):
    merge
    | directory
    | basename
    | formats($all_formats)
    | link
    | clean
    | frontmatter
    | sorting
    | navigation
    | annotate_leaves
;

# Get target files and their dependencies as an enumeration of {"target":...,
# "dependencies":...} objects.
def targets($dest):
    entries
    | ., (.frontmatter // empty)
    | .formats[] as $format
    | "\($dest)/\(.dir)/\(.basename).\($format)" as $doc
    | ["\($dest)/\(.dir)/\(.resources?[])"] as $external
    | ["\($dest)/\(.style//empty).css"] as $css
    | [ .next.source//empty, .prev.source//empty ] as $neighbours
    | (if $format == "html" then ($css + $external) else [] end) as $linked
    | (if $format == "pdf"  then ($css + $external) else [] end) as $embedded
    | (if $format == "html" then $neighbours else [] end) as $triggers
    | ({next,prev} | flat_obj | to_entries | map("--metadata","\(.key)=\(.value)")) as $args
    | {"target": $format, "dependencies": ([$doc] + $linked) }
    , {"target": $doc, "dependencies": ($embedded + $triggers) }
    , {"target": $doc, "dependencies": ["EXTRA_PANDOC_ARGS:=\( $args | @sh )"]
    }
;
