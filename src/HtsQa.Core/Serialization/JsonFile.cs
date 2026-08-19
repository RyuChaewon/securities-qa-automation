// 역할: UTF-8 JSON 파일 입출력과 원본·계획 추적용 SHA-256 계산을 한곳에서 제공한다.
// 입력/출력: 파일 경로와 타입을 받아 JsonDefaults 계약으로 읽고 쓰며 실제 파일 바이트의 해시를 반환한다.
// 경계: 도메인 검증은 호출자가 담당하고 이 계층은 직렬화·파일 무결성에만 집중한다.
// 수정 지점: 해시는 승인 원본 동일성에 사용되므로 정규화 없이 실제 바이트를 계산해야 한다.
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace HtsQa.Core;

/// <summary>프로그램 전반의 JSON 저장, 로드 및 무결성 해시 계산을 담당한다.</summary>
public static class JsonFile
{
    /// <summary>지정한 JSON 파일을 공통 직렬화 옵션으로 역직렬화한다.</summary>
    public static T Read<T>(string path)
    {
        using var stream = File.OpenRead(path);
        return JsonSerializer.Deserialize<T>(stream, JsonDefaults.Options)
            ?? throw new InvalidDataException($"Could not deserialize {path}");
    }

    /// <summary>값을 UTF-8(BOM 없음) JSON으로 저장하고 상위 폴더를 자동 생성한다.</summary>
    public static void Write<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        File.WriteAllText(path, JsonSerializer.Serialize(value, JsonDefaults.Options), new UTF8Encoding(false));
    }

    /// <summary>파일 원본 바이트의 SHA-256을 계산해 승인 및 설치 동일성 추적에 사용한다.</summary>
    public static string Sha256Bytes(string path)
    {
        using var sha = SHA256.Create();
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(sha.ComputeHash(stream)).ToLowerInvariant();
    }

    /// <summary>값의 공통 JSON 표현에 대한 SHA-256을 계산해 결정론적 계획 ID 생성에 사용한다.</summary>
    public static string Sha256Json<T>(T value)
    {
        using var sha = SHA256.Create();
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, JsonDefaults.Options);
        return Convert.ToHexString(sha.ComputeHash(bytes)).ToLowerInvariant();
    }
}
