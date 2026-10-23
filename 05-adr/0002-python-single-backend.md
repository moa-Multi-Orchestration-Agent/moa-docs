# 0002. 백엔드 Python 단일 스택

- 상태: 검토 중
- 날짜: 2026-10-13

## 배경
AI 핵심 라이브러리(LangGraph, MCP SDK, tiktoken, Blender bpy)가 모두 Python이다. 한편 취업 시장에서는 Spring 경험도 중요하다.

## 선택지
1. **Python(FastAPI) 단일** — 서버 1개, 인증·배포 단순 / Spring 경험 없음
2. **Spring(계정·마켓·과금) + Python(AI)** — 역할 분리, Spring 경험 / 서버 2개 운영, 인증 공유, 배포 이중화

## 결정
(팀 결정 후 기록)

## 결과
모듈 경계(설계서 1.3.3)를 지키면 계정·마켓·과금을 나중에 Spring으로 분리할 수 있다.
