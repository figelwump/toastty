export interface ReportMark { shot: string; note: string; x: number; y: number }

export function marksMessage(marks: ReportMark[]): string {
  return `${marks.length} mark${marks.length === 1 ? "" : "s"} on the screenshots:\n` + marks.map((m, i) => `${i + 1}. ${m.note.trim().replace(/\s+/g, " ")} [${m.shot}]`).join("\n");
}

export function validMarks(marks: ReportMark[], screenshots: string[]): boolean {
  return marks.length > 0 && marks.length <= 100 && marks.every((m) => screenshots.includes(m.shot) && m.note.trim() && !/[\u0000-\u0008\u000e-\u001f\u007f-\u009f]/.test(m.note)
    && Number.isFinite(m.x) && Number.isFinite(m.y) && m.x >= 0 && m.x <= 1 && m.y >= 0 && m.y <= 1)
    && new TextEncoder().encode(marksMessage(marks)).length <= 16 * 1024;
}
