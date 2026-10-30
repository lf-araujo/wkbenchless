## test_supplement -- #+SUPPLEMENT: relabelling (wkblayout.expandSupplement):
## supplement figures/tables leave pandoc-crossref's sequence under their own
## label template, refs to them become internal links, and otd-import's
## restoreSuppRefs turns those links back into cross-refs.
##   nim c -r --hints:off src/test_supplement.nim
import std/[strutils, sequtils]
import wkblayout
import ../extensions/org_tracked

var fails = 0
template check(name: string; cond: bool) =
  if cond: echo "ok   ", name
  else: echo "FAIL ", name; inc fails

const doc = """#+SUPP_TABLE_LABEL: eTable %n
#+SUPP_FIGURE_LABEL: Supplementary Fig. %n
Main [cite:@tbl:main], supp [cite:@tbl:a;@fig:b] and [cite:@tbl:main;@tbl:c;@smith2020].

#+name: tbl:main
#+caption: Main.
| x |

#+SUPPLEMENT: begin
#+caption: First supp table, see [cite:@fig:b].
#+name: tbl:a
| x |

#+name: fig:b
#+caption: A figure.
[[file:b.png]]

#+name: tbl:c
| x |

#+name: fig:src
#+begin_src R
plot(1)
#+end_src"""

block docx:
  let o = expandSupplement(doc.splitLines, ltDocx).join("\n")
  check "main table keeps its crossref id", "#+name: tbl:main" in o
  check "main ref stays a citation", "Main [cite:@tbl:main]," in o
  check "supp table renamed out of crossref", "#+name: supp-tbl-a" in o and "tbl:a\n" notin o
  check "caption before #+name: is prefixed",
    "#+caption: eTable 1: First supp table, see [[#supp-fig-b][Supplementary Fig. 1]]." in o
  check "caption after #+name: is prefixed", "#+caption: Supplementary Fig. 1: A figure." in o
  check "uncaptioned item gets a bare label", "#+name: supp-tbl-c\n#+caption: eTable 2" in o
  check "grouped supp refs become links",
    "supp [[#supp-fig-b][Supplementary Fig. 1]], [[#supp-tbl-a][eTable 1]] and" in o
  check "mixed group keeps the rest as a citation",
    "[[#supp-tbl-c][eTable 2]], [cite:@tbl:main;@smith2020]" in o
  check "src block names are not supplement items", "#+name: fig:src" in o
  check "directive lines dropped", "SUPPLEMENT" notin o and "SUPP_" notin o

block plural:
  var many = @["#+SUPPLEMENT: begin"]
  for k in 1 .. 5: many.add @["#+name: fig:f" & $k, "#+caption: c", "[[file:x.png]]", ""]
  many.add "See [cite:@fig:f1;@fig:f2;@fig:f3] and [cite:@fig:f1;@fig:f2;@fig:f4]."
  let o = expandSupplement(many, ltDocx).join("\n")
  check "consecutive run becomes a plural range",
    "See [[#supp-fig-f1][Figures S1–S3]] and" in o
  check "short runs are listed",
    "and [[#supp-fig-f1][Figures S1, S2 and S4]]." in o
  let et = expandSupplement(@["#+SUPP_TABLE_LABEL: eTable %n"] & many.mapIt(it.replace("fig:", "tbl:")), ltDocx).join("\n")
  check "eTable pluralizes", "[[#supp-tbl-f1][eTables 1–3]]" in et

block latex:
  let o = expandSupplement(doc.splitLines, ltLatex).join("\n")
  check "latex keeps crossref ids", "#+name: tbl:a" in o
  check "latex redefines float names",
    "\\renewcommand{\\tablename}{eTable}\\renewcommand{\\thetable}{\\arabic{table}}" in o and
    "\\renewcommand{\\figurename}{Supplementary Fig.}" in o
  let s = expandSupplement("#+SUPPLEMENT: begin".splitLines, ltLatex).join("\n")
  check "default Figure S%n -> S prefix", "\\renewcommand{\\thefigure}{S\\arabic{figure}}" in s

block reimport:
  check "supp links restore to cross-refs",
    restoreSuppRefs("see [[#supp-tbl-a][eTable 1]] and [[#supp-fig-b-2][Fig. S1]].") ==
      "see [cite:@tbl:a] and [cite:@fig:b-2]."

if fails > 0: quit 1
