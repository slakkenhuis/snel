#!/usr/bin/env jq
# This is a collection of filters for `jq`, intended to manipulate JSON objects
# into JSON representing a website index, for further processing in a template.

# Convert "truthy" value to actual boolean.
def bool:
    [. == (null,false,0,{},[])] | any | not
;

# Generate this object and all its children.
def all_children:
    ., recurse(.contents[]?)
;

# To remove an object, we first mark it for removal, then actually remove it
# later. It would be nicer if we could just do `all_children ... |= empty`,
# which works in some cases but not all. I suppose it has to do with changing
# objects as we are iterating over them.
def mark:
    .remove = true
;

# Remove all objects marked for removal.
def remove_marked:
    if .remove == true
    then empty
    else (.contents // empty) |= map(remove_marked)
    end
;

# Wrap an object in other objects so that the original object exists at a
# particular "path". Like `{} | setpath(["a","b"], …)`, but instead of making
# objects like `{"a":{"b":…}}`, this makes objects like `{"name":"a",
# "contents":[{"name":"b",…}]}`.
def tree($path):
    if ($path | length) <= 1
    then .name = $path[0]
    else { "name": $path[0], "contents": [ tree($path[1:]) ] }
    end
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
            else error("can't merge incompatible values")
            end
        ) }
    ) | from_entries
;

# Add paths to each object, that is, the names of the ancestors.
def directory:
    def f($d): .directory = $d | .name as $n | .contents[]? |= f($d+[$n]);
    f([])
;

# Every leaf node gets a basename, eg name without extension.
def basename:
    (all_children | select(has("contents") | not)) |= (
        .basename = (.name | sub(".([A-z]*)$";""))
    )
;

# Any Markdown page gets a link to its HTML page.
def link:
    (all_children | select(has("directory") and has("basename") and (.name | test(".(md|markdown)$";"i")))) |= (
        .link = ((.directory + [.basename + ".html"]) | join("/") | ltrimstr("./"))
    )
;

# Front matter is the page to be associated with the enclosing directory rather
# than itself.
def frontmatter:
    (all_children | select(has("contents"))) |= (
        (.frontmatter = [.contents[] | select(.meta.frontmatter | bool)][0]) |
        (.contents = .contents - [.frontmatter])
    )
;

# Drafts can be excluded from being uploaded and included in the table of
# contents. To not count as a draft, a document should be explicitly marked as
# "publish" in the metadata.
def explicit_publish:
    def publish: has("contents") or .external or .meta.publish | bool;
    (( all_children | select(publish | not)) |= mark) | remove_marked
;

# Sort content first according to sort order in metadata.
def sort_content:
    (all_children | select(has("contents")) | .contents) |= (
        sort_by(.meta.sort // .meta.title // .name)
    )
;

# Add a note that tells us whether this has only children who have no more
# subchildren.
def annotate_leaves:
    (all_children | select(has("contents"))) |= (
        .only_leaves = (.contents | all(has("contents") | not))
    )
;

# Combines the given stream of JSON objects by merging them, and performs the
# given operations to turn it into a proper index.
def index:
    merge
    | directory
    | basename
    | link
    | explicit_publish
    | frontmatter
    | sort_content
    | annotate_leaves
;

# Get a list of target documents and their Makefile dependencies as an array of
# {"target":..., "deps":...} objects.
def targets($dest; $style_html; $style_pdf):
    def in_dir($dir; $file):
        $dir + [$file] | join("/") | ltrimstr("./") | ($dest + "/" + .)
    ;
    [ all_children
        | ., (.frontmatter // empty)
        | select(has("directory") and has("basename") and (has("external") | not)) 
        | in_dir(.directory; .basename + ".pdf") as $pdf
        | in_dir(.directory; .basename + ".html") as $html
        | [in_dir(["."]; (.meta.style // $style_html) + ".css")] as $css_html
        | [in_dir(["."]; (.meta.style // $style_pdf) + ".css")] as $css_pdf
        | [in_dir(.directory; .targets?[])] as $external
        | {"target": "pdf", "deps": [$pdf]}
        , {"target": "html", "deps": ([$html] + $css_html + $external)}
        , {"target": $html, "deps": [] }
        , {"target": $pdf, "deps": ($css_pdf + $external)}
    ]
    | group_by(.target)
    | map({"target":(.[0].target), "deps": (map(.deps) | add | unique)})
    | . // []
;

# Turn a target object into makefile recipes.
def as_makefile:
    .[] | (.target + ": " + (.deps | join(" ")))
;
