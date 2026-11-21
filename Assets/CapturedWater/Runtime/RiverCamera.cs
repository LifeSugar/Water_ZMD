using UnityEngine;

namespace CapturedWater
{
    [DisallowMultipleComponent, RequireComponent(typeof(Camera))]
    public sealed class RiverCamera : MonoBehaviour
    {
        [Min(0)] public float moveSpeed = 6;
        [Tooltip("Hold the right mouse button to look. WASD moves, Q/E changes height, and R returns to the starting view.")]
        public bool flyCamera = true;

        Camera view;
        Vector3 startPosition;
        Quaternion startRotation;
        float startFieldOfView;

        void Awake()
        {
            view = GetComponent<Camera>();
            startPosition = transform.position;
            startRotation = transform.rotation;
            startFieldOfView = view.fieldOfView;
        }

        public void ResetView()
        {
            transform.SetPositionAndRotation(startPosition, startRotation);
            view.fieldOfView = startFieldOfView;
        }

        void Update()
        {
            if (!flyCamera) return;
            if (Input.GetKeyDown(KeyCode.R)) ResetView();
            if (!Input.GetMouseButton(1)) return;
            var angles = transform.eulerAngles;
            float pitch = Mathf.Clamp(Mathf.DeltaAngle(0, angles.x) - Input.GetAxisRaw("Mouse Y") * 2, -87, 87);
            transform.rotation = Quaternion.Euler(pitch, angles.y + Input.GetAxisRaw("Mouse X") * 2, 0);
            float lift = (Input.GetKey(KeyCode.E) ? 1 : 0) - (Input.GetKey(KeyCode.Q) ? 1 : 0);
            var move = transform.forward * Input.GetAxisRaw("Vertical") + transform.right * Input.GetAxisRaw("Horizontal") + Vector3.up * lift;
            float speed = Input.GetKey(KeyCode.LeftShift) ? moveSpeed * 3 : moveSpeed;
            transform.position += Vector3.ClampMagnitude(move, 1) * speed * Time.unscaledDeltaTime;
        }
    }
}
