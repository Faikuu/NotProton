#!/usr/bin/env python3
# Self-test for the stack-slot guards in resolve.amd64_load_path, which a build the pinned
# hashes do not cover relies on. Needs capstone installed (resolve imports it).
#   python3 -I test_resolve.py
import os, sys, unittest
from collections import namedtuple
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import resolve

Insn = namedtuple('Insn', 'address mnemonic op_str')
HOOK = 0x1000


class Pe:
    path = 'synthetic.dll'


def seq(*texts):
    out = []
    for n, t in enumerate(texts):
        mnemonic, _, ops = t.partition(' ')
        out.append(Insn(0x100 + n * 4, mnemonic, ops))
    return out


def run(*texts):
    return resolve.amd64_load_path(Pe(), seq(*texts), HOOK)


FRAME = ('lea rbp, [rsp + 0x80]', 'mov qword ptr [rbp - 0x30], rcx')


class LoadPathGuards(unittest.TestCase):
    def test_rbp_frame_slot_is_rsp_relative(self):
        self.assertEqual(run(*FRAME, 'mov rax, qword ptr [rbp + 0x10]', 'call 0x2000'), 0x50)

    def test_rsp_slot_unchanged(self):
        self.assertEqual(run('mov qword ptr [rsp + 0x98], rcx', 'mov rax, rdx'), 0x98)

    def test_register_stash_then_rsp_slot(self):
        self.assertEqual(run('mov rbx, rcx', 'mov qword ptr [rsp + 0x20], rbx'), 0x20)

    def test_reads_of_the_slot_are_fine(self):
        self.assertEqual(run(*FRAME, 'mov rax, qword ptr [rbp - 0x30]', 'cmp qword ptr [rbp - 0x30], 0'), 0x50)

    def refuses(self, *between):
        with self.assertRaises(SystemExit, msg=between):
            run(FRAME[0], *between[:0], FRAME[1], *between)

    def test_rbp_changes_are_refused(self):
        for bad in ('mov ebp, eax', 'inc rbp', 'and rbp, -0x10', 'lea rbp, [rsp + 0x40]',
                    'add rbp, 8', 'sub rbp, 8', 'xchg rbp, rax', 'xchg rax, rbp', 'pop rbp', 'leave'):
            with self.subTest(bad):
                self.refuses(bad)

    def test_rsp_changes_are_refused(self):
        for bad in ('lea rsp, [rsp - 8]', 'mov rsp, rbp', 'and rsp, -0x10', 'sub rsp, 8',
                    'add rsp, 8', 'push rax', 'pop rax', 'xchg rsp, rax'):
            with self.subTest(bad):
                self.refuses(bad)

    def test_slot_rewrites_are_refused(self):
        for bad in ('mov qword ptr [rbp - 0x30], rax', 'mov dword ptr [rbp - 0x30], eax',
                    'add qword ptr [rbp - 0x30], 8', 'mov qword ptr [rsp + 0x50], rax',
                    'xchg qword ptr [rbp - 0x30], rax'):
            with self.subTest(bad):
                self.refuses(bad)

    def test_rsp_direct_slot_rewrites_and_moves_are_refused(self):
        for bad in ('mov qword ptr [rsp + 0x98], rax', 'lea rsp, [rsp - 8]', 'mov rsp, rbp', 'and rsp, -0x10'):
            with self.subTest(bad):
                with self.assertRaises(SystemExit):
                    run('mov qword ptr [rsp + 0x98], rcx', bad)

    def test_slot_zero_spelling(self):
        self.assertEqual(run('mov qword ptr [rsp], rcx'), 0)
        with self.assertRaises(SystemExit):
            run('mov qword ptr [rsp], rcx', 'mov qword ptr [rsp], rax')

    def test_no_store_at_all_is_refused(self):
        with self.assertRaises(SystemExit):
            run('mov rax, rdx')


if __name__ == '__main__':
    unittest.main()
